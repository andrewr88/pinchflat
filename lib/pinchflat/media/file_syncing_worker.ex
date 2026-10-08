defmodule Pinchflat.Media.FileSyncingWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    tags: ["sources", "local_data"],
    # A refused sync is recorded as failed instead of being retried for days. The sync is
    # started by hand, so it can just be started again once the media directory is back
    max_attempts: 1

  require Logger

  alias __MODULE__
  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Media.FileSyncing

  @doc """
  Starts the source file syncing worker.

  Returns {:ok, %Task{}} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(source, opts \\ []) do
    %{id: source.id}
    |> FileSyncingWorker.new(opts)
    |> Tasks.create_job_with_task(source)
  end

  @doc """
  Clears the stored paths of a source's files that no longer exist on disk
  (see `FileSyncing.sync_file_presence_on_disk/1`).

  An unmounted media directory makes every file look missing, and clearing all their
  paths would make the whole source pending (so its next index downloads all of it again).
  So nothing is changed if the media directory is missing or empty, or if the source has
  downloaded media and none of those media files exist. The refusal is logged and
  returned, so Oban records the job as failed.

  Returns :ok | {:error, String.t()}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => source_id}}) do
    source = Repo.preload(Sources.get_source!(source_id), :media_items)

    case check_files_can_be_synced(source.media_items) do
      :ok ->
        FileSyncing.sync_file_presence_on_disk(source.media_items)

        :ok

      {:error, reason} ->
        Logger.error("Not syncing files on disk for source ##{source.id} (#{source.custom_name}): #{reason}")

        {:error, reason}
    end
  end

  defp check_files_can_be_synced(media_items) do
    media_directory = Application.get_env(:pinchflat, :media_directory)
    media_filepaths = for %{media_filepath: filepath} when is_binary(filepath) <- media_items, do: filepath

    cond do
      not match?({:ok, [_ | _]}, File.ls(media_directory)) ->
        {:error, "the media directory #{inspect(media_directory)} is missing or empty, so it may not be mounted"}

      media_filepaths != [] and not Enum.any?(media_filepaths, &File.exists?/1) ->
        {:error,
         "none of the source's #{length(media_filepaths)} downloaded media files exist, " <>
           "so the media directory may not be mounted"}

      true ->
        :ok
    end
  end
end
