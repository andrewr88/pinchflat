defmodule Pinchflat.Metadata.SourceMetadataStorageWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :remote_metadata,
    tags: ["media_source", "source_metadata", "remote_metadata", "show_in_dashboard"],
    max_attempts: 3

  import Ecto.Query, warn: false

  require Logger

  alias __MODULE__
  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Utils.StringUtils
  alias Pinchflat.Metadata.NfoBuilder
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.YtDlp.MediaCollection
  alias Pinchflat.Metadata.SourceImageParser
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Downloading.DownloadOptionBuilder

  @doc """
  Starts the source metadata storage worker and creates a task for the source.

  Returns {:ok, %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(source, opts \\ []) do
    %{id: source.id}
    |> SourceMetadataStorageWorker.new(opts)
    |> Tasks.create_job_with_task(source)
  end

  @doc """
  Fetches and stores various forms of metadata for a source:
    - Attributes like `description`
    - JSON metadata for internal use
    - The series directory for the source
    - The NFO file for the source (if specified)
    - Downloads and stores source images (if specified)

  The worker is kicked off after a source is inserted or it's original_url
  is updated - this can take an unknown amount of time so don't rely on this
  data being here before, say, the first indexing or downloading task is complete.

  Once the source is updated, the files its NFO and image paths pointed to before
  (and no longer do) are deleted, e.g. the old `tvshow.nfo` once the profile stops
  downloading NFOs, or the old series directory's NFO and images once it changes.

  Returns :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => source_id}}) do
    source = Repo.preload(Sources.get_source!(source_id), [:metadata, :media_profile])
    series_directory = determine_series_directory(source)

    {source_metadata, source_image_attrs, metadata_image_attrs} =
      fetch_source_metadata_and_images(series_directory, source)

    source_metadata_filepath = MetadataFileHelpers.compress_and_store_metadata_for(source, source_metadata)

    update_result =
      Sources.update_source(
        source,
        Map.merge(
          %{
            series_directory: series_directory,
            nfo_filepath: store_source_nfo(source, series_directory, source_metadata),
            description: source_metadata["description"],
            metadata: Map.merge(%{metadata_filepath: source_metadata_filepath}, metadata_image_attrs)
          },
          source_image_attrs
        ),
        # `run_post_commit_tasks: false` prevents this from running in an infinite loop
        run_post_commit_tasks: false
      )

    with {:ok, updated_source} <- update_result do
      delete_replaced_source_files(source, updated_source)
    end

    :ok
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: source #{source_id} not found")
    Ecto.StaleEntryError -> Logger.info("#{__MODULE__} discarded: source #{source_id} stale")
  end

  defp fetch_source_metadata_and_images(series_directory, source) do
    metadata_directory = MetadataFileHelpers.metadata_directory_for(source)

    {:ok, metadata} = fetch_metadata_for_source(source)
    metadata_image_attrs = SourceImageParser.store_source_images(metadata_directory, metadata)

    if source.media_profile.download_source_images && series_directory do
      source_image_attrs = SourceImageParser.store_source_images(series_directory, metadata)

      {metadata, source_image_attrs, metadata_image_attrs}
    else
      {metadata, %{}, metadata_image_attrs}
    end
  end

  defp determine_series_directory(source) do
    output_path = DownloadOptionBuilder.build_output_path_for(source)
    runner_opts = [output: output_path]
    addl_opts = [use_cookies: Sources.use_cookies?(source, :metadata)]
    {:ok, %{filepath: filepath}} = MediaCollection.get_source_details(source.original_url, runner_opts, addl_opts)

    case MetadataFileHelpers.series_directory_from_media_filepath(filepath) do
      {:ok, series_directory} -> series_directory
      {:error, _} -> nil
    end
  end

  defp store_source_nfo(source, series_directory, metadata) do
    if source.media_profile.download_nfo && series_directory do
      nfo_filepath = Path.join(series_directory, "tvshow.nfo")

      NfoBuilder.build_and_store_for_source(nfo_filepath, metadata)
    end
  end

  # Deletes the files the source's NFO and image paths pointed to before the update and no longer
  # do, so they aren't left behind untracked. A file is kept if it's still one of the source's
  # files (the same path, or the same file under another path, e.g. after a case-only change on a
  # case-insensitive filesystem), if another source still uses it (sources for the same channel can
  # share a series directory), or if it's outside the media directory. The source images in the
  # internal metadata directory are separate fields and aren't touched
  defp delete_replaced_source_files(old_source, new_source) do
    media_directory = Application.get_env(:pinchflat, :media_directory)
    new_filepaths = source_filepaths(new_source)

    old_source
    |> source_filepaths()
    |> Enum.filter(&File.exists?/1)
    |> Enum.reject(&(same_file_as_any?(&1, new_filepaths) or used_by_another_source?(&1, old_source)))
    |> Enum.each(&FilesystemUtils.delete_file_inside_directory(&1, media_directory))
  end

  defp source_filepaths(source) do
    source
    |> Map.take(Source.filepath_attributes())
    |> Map.values()
    |> Enum.filter(&is_binary/1)
  end

  defp same_file_as_any?(filepath, other_filepaths) do
    Enum.any?(other_filepaths, fn other_filepath ->
      File.exists?(other_filepath) and FilesystemUtils.filepaths_reference_same_file?(filepath, other_filepath)
    end)
  end

  defp used_by_another_source?(filepath, source) do
    Source
    |> where([s], s.id != ^source.id)
    |> where(
      [s],
      s.nfo_filepath == ^filepath or s.poster_filepath == ^filepath or
        s.fanart_filepath == ^filepath or s.banner_filepath == ^filepath
    )
    |> Repo.exists?()
  end

  defp fetch_metadata_for_source(source) do
    tmp_output_path = "#{tmp_directory()}/#{StringUtils.random_string(16)}/source_image.%(ext)S"
    base_opts = [convert_thumbnails: "jpg", output: tmp_output_path]
    should_use_cookies = Sources.use_cookies?(source, :metadata)

    opts =
      if source.collection_type == :channel do
        base_opts ++ [:write_all_thumbnails, playlist_items: 0]
      else
        base_opts ++ [:write_thumbnail, playlist_items: 1]
      end

    MediaCollection.get_source_metadata(source.original_url, opts, use_cookies: should_use_cookies)
  end

  defp tmp_directory do
    Application.get_env(:pinchflat, :tmpfile_directory)
  end
end
