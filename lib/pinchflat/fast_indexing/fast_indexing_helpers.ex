defmodule Pinchflat.FastIndexing.FastIndexingHelpers do
  @moduledoc """
  Methods for performing fast indexing tasks and managing the fast indexing process.

  Many of these methods are made to be kickoff or be consumed by workers.
  """

  require Logger

  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.FastIndexing.YoutubeRss
  alias Pinchflat.FastIndexing.YoutubeApi
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.FastIndexing.FastIndexingWorker
  alias Pinchflat.Downloading.DownloadOptionBuilder

  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  # %{source UUID => %{media ID => %{short_form_content: boolean(), livestream: boolean()}}} for media that was
  # skipped since its source doesn't index its type. See `index_and_kickoff_downloads/1`
  @skipped_media_agent {:global, __MODULE__.SkippedMedia}

  @doc """
  Kicks off a new fast indexing task for a source. This will delete any existing fast indexing
  tasks for the source before starting a new one.

  Returns {:ok, %Task{}}
  """
  def kickoff_indexing_task(%Source{} = source) do
    Tasks.delete_pending_tasks_for(source, "FastIndexingWorker", include_executing: true)
    FastIndexingWorker.kickoff_with_task(source)
  end

  @doc """
  Fetches new media IDs for a source from YT's API or RSS, indexes them, and kicks off downloading
  tasks for any pending media items. See comments in `FastIndexingWorker` for more info on the
  order of operations and how this fits into the indexing process.

  Returns [%MediaItem{}] where each item is a new media item that was created _but not necessarily
  downloaded_. If the media IDs can't be fetched, the error is logged and treated as if no new media
  was found (ie: returns [] but still kicks off downloads for pending media items).

  Media whose type the source doesn't index (see `Sources.indexes_media_type?/2`, eg: a short when the
  source doesn't scan its channel's Shorts tab) isn't created. Since it'd otherwise be fetched again by
  every fast index while it's among the source's recent media (eg: a channel's feed can be mostly shorts),
  it's remembered (in memory) and only fetched again if the source indexes its type by then. A livestream
  without a duration (ie: it hasn't happened yet or is still live) isn't remembered as it can turn out to
  be a regular video (eg: a premiere).
  """
  def index_and_kickoff_downloads(%Source{} = source) do
    # The media_profile is needed to determine the quality options to _then_ determine a more
    # accurate predicted filepath
    source = Repo.preload(source, [:media_profile])

    # Don't raise on a failed fetch - `FastIndexingWorker` relies on this returning so it can
    # reschedule itself on its normal cadence rather than falling back to Oban's retry backoff
    media_ids =
      case get_recent_media_ids(source) do
        {:ok, media_ids} ->
          media_ids

        {:error, reason} ->
          Logger.warning("Could not fetch recent media IDs for source #{source.id}: #{inspect(reason)}")
          []
      end

    existing_media_items = list_media_items_by_media_id_for(source, media_ids)
    new_media_ids = media_ids -- Enum.map(existing_media_items, & &1.media_id)

    {maybe_new_media_items, skipped_media} =
      Enum.map_reduce(new_media_ids, get_skipped_media(source), fn media_id, skipped_media ->
        case create_media_item_from_media_id(source, media_id, skipped_media) do
          {:ok, media_item} ->
            DownloadingHelpers.kickoff_download_if_pending(media_item, priority: 0)
            {media_item, Map.delete(skipped_media, media_id)}

          {:skipped, media} ->
            {nil, put_skipped_media(skipped_media, media_id, media)}

          err ->
            Logger.error("Error creating media item '#{media_id}' from URL: #{inspect(err)}")
            {nil, skipped_media}
        end
      end)

    save_skipped_media(source, media_ids, skipped_media)

    # Pick up any stragglers. Intentionally has a lower priority than the per-media item
    # kickoff above
    DownloadingHelpers.enqueue_pending_download_tasks(source, priority: 1)

    Enum.filter(maybe_new_media_items, & &1)
  end

  # If possible, use the YouTube API to fetch media IDs. If that fails, fall back to the RSS feed.
  # If the YouTube API isn't set up, just use the RSS feed.
  defp get_recent_media_ids(source) do
    with true <- YoutubeApi.enabled?(),
         {:ok, media_ids} <- YoutubeApi.get_recent_media_ids(source) do
      {:ok, media_ids}
    else
      _ -> YoutubeRss.get_recent_media_ids(source)
    end
  end

  defp list_media_items_by_media_id_for(source, media_ids) do
    MediaQuery.new()
    |> where(^dynamic([mi], ^MediaQuery.for_source(source) and mi.media_id in ^media_ids))
    |> Repo.all()
  end

  # Media that was skipped before isn't fetched again unless the source indexes its type now
  defp create_media_item_from_media_id(source, media_id, skipped_media) do
    case Map.fetch(skipped_media, media_id) do
      {:ok, media} ->
        if Sources.indexes_media_type?(source, media) do
          fetch_and_create_media_item(source, media_id)
        else
          {:skipped, media}
        end

      :error ->
        fetch_and_create_media_item(source, media_id)
    end
  end

  defp fetch_and_create_media_item(source, media_id) do
    url = "https://www.youtube.com/watch?v=#{media_id}"
    # This is set to :metadata instead of :indexing since this happens _after_ the
    # actual indexing process. In reality, slow indexing is the only thing that
    # should be using :indexing.
    should_use_cookies = Sources.use_cookies?(source, :metadata)

    command_opts =
      [output: DownloadOptionBuilder.build_output_path_for(source)] ++
        DownloadOptionBuilder.build_quality_options_for(source)

    case YtDlpMedia.get_media_attributes(url, command_opts, use_cookies: should_use_cookies) do
      {:ok, media_attrs} ->
        if Sources.indexes_media_type?(source, media_attrs) do
          Media.create_media_item_from_backend_attrs(source, media_attrs)
        else
          {:skipped, media_attrs}
        end

      err ->
        err
    end
  end

  defp put_skipped_media(skipped_media, _media_id, %{livestream: true, duration_seconds: nil}), do: skipped_media

  defp put_skipped_media(skipped_media, media_id, media) do
    Map.put(skipped_media, media_id, Map.take(media, [:short_form_content, :livestream]))
  end

  defp get_skipped_media(source) do
    Agent.get(skipped_media_agent(), &Map.get(&1, source.uuid, %{}))
  end

  # Only media that's still among the source's recent media is kept. Nothing changes if they couldn't be fetched
  defp save_skipped_media(_source, [] = _media_ids, _skipped_media), do: :ok

  defp save_skipped_media(source, media_ids, skipped_media) do
    kept = Map.take(skipped_media, media_ids)

    Agent.update(skipped_media_agent(), fn all_skipped_media ->
      if map_size(kept) == 0,
        do: Map.delete(all_skipped_media, source.uuid),
        else: Map.put(all_skipped_media, source.uuid, kept)
    end)
  end

  defp skipped_media_agent do
    case Agent.start(fn -> %{} end, name: @skipped_media_agent) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
