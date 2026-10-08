defmodule Pinchflat.Downloading.MediaDownloadWorker do
  @moduledoc false

  # Unique per media item, whatever the other args: two jobs at once would download to the same files
  use Oban.Worker,
    queue: :media_fetching,
    priority: 5,
    unique: [period: :infinity, keys: [:id], states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_item", "media_fetching", "show_in_dashboard"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Tasks
  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.FileSyncing
  alias Pinchflat.Downloading.MediaDownloader

  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner

  @doc """
  Starts the media_item media download worker and creates a task for the media_item.

  A media item has at most one download job queued or running, whatever its args, so
  this returns `{:error, :duplicate_job}` if there's one already. The exception is a
  forced download: it's an explicit request from the user, so it replaces a queued
  (not running) download, which might otherwise not download at all or be waiting to retry.

  Returns {:ok, %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(media_item, job_args \\ %{}, job_opts \\ []) do
    if job_args[:force] || job_args["force"] do
      Tasks.delete_pending_tasks_for(media_item, "MediaDownloadWorker")
    end

    %{id: media_item.id}
    |> Map.merge(job_args)
    |> MediaDownloadWorker.new(job_opts)
    |> Tasks.create_job_with_task(media_item)
  end

  @doc """
  For a given media item, download the media alongside any options.
  Does not download media if its source is set to not download media
  (unless forced).

  Options:
    - `force`: force download even if the source is set to not download media. Fully
      re-downloads media, including the video
    - `quality_upgrade?`: re-downloads media, including the video. Does not force download
      if the source is set to not download media
    - `redownload?`: also downloads media that has already been downloaded, without overwriting
      existing files (eg: to fetch thumbnails or subtitles that have since been enabled). Does not
      force download if the source is set to not download media. A media file left in place keeps
      its download date

  Returns :ok | {:error, any, ...any}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => media_item_id} = args}) do
    should_force = Map.get(args, "force", false)
    is_quality_upgrade = Map.get(args, "quality_upgrade?", false)
    is_redownload = Map.get(args, "redownload?", false)

    media_item =
      media_item_id
      |> Media.get_media_item!()
      |> Repo.preload(:source)

    # The pre-download user script only runs once we know the media would otherwise be downloaded
    if should_download_media?(media_item, should_force, is_quality_upgrade, is_redownload) &&
         pre_download_user_script_allows?(media_item, should_force) do
      download_media_and_schedule_jobs(media_item, is_quality_upgrade, should_force, is_redownload)
    else
      :ok
    end
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: media item #{media_item_id} not found")
    Ecto.StaleEntryError -> Logger.info("#{__MODULE__} discarded: media item #{media_item_id} stale")
  end

  # If this is a quality upgrade, only check if the source is set to download media
  # or that the media item's download hasn't been prevented
  defp should_download_media?(media_item, should_force, true = _is_quality_upgrade, _is_redownload) do
    (media_item.source.download_media && !media_item.prevent_download) || should_force
  end

  # If it's not a quality upgrade, additionally check if the media item is pending download.
  # A redownload of existing media also accepts media that's already downloaded (which is never pending)
  defp should_download_media?(media_item, should_force, _is_quality_upgrade, is_redownload) do
    source = media_item.source
    is_downloaded = media_item.media_filepath != nil
    is_eligible = (is_redownload && is_downloaded) || Media.pending_download?(media_item)

    (is_eligible && source.download_media && !media_item.prevent_download) || should_force
  end

  # If a user script exists and, when run, returns an exit code from 1 to 125, that's a veto: prevent this and all
  # future downloads of the media item.
  #
  # Higher exit codes mean the script never got to decide: it couldn't run (126: the lifecycle file isn't executable,
  # 127: it or its interpreter wasn't found) or it was killed (128 + the signal's number). That's logged as an error
  # and the media is downloaded anyway, since a broken script would otherwise prevent every download for good.
  #
  # Forced downloads are an explicit request from the user and already override `prevent_download`, so the
  # script still runs (keeping it paired with the `media_downloaded` script) but its veto is ignored and not
  # saved. Saving it would quietly drop media the user just downloaded from quality upgrades and redownloads.
  # Any later download that isn't forced runs the script again, so it can still veto those.
  defp pre_download_user_script_allows?(media_item, should_force) do
    case {run_user_script(:media_pre_download, media_item), should_force} do
      {{:ok, _, exit_code}, true} when exit_code in 1..125 ->
        Logger.info("Pre-download user script vetoed media item ##{media_item.id} but it's forced. Downloading anyway")

        true

      {{:ok, _, exit_code}, _} when exit_code in 1..125 ->
        {:ok, _} = Media.update_media_item(media_item, %{prevent_download: true})

        false

      {{:ok, _, exit_code}, _} when exit_code != 0 ->
        Logger.error(
          "Pre-download user script #{UserScriptRunner.lifecycle_filepath()} failed with exit code #{exit_code} " <>
            "(#{describe_script_failure(exit_code)}). Only exit codes from 1 to 125 are a veto, so media item " <>
            "##{media_item.id} is downloaded anyway"
        )

        true

      _ ->
        true
    end
  end

  defp describe_script_failure(126), do: "the file isn't executable"
  defp describe_script_failure(127), do: "the file or its interpreter wasn't found"
  defp describe_script_failure(_exit_code), do: "it was killed by a signal"

  defp download_media_and_schedule_jobs(media_item, is_quality_upgrade, should_force, is_redownload) do
    overwrite_behaviour = if should_force || is_quality_upgrade, do: :force_overwrites, else: :no_force_overwrites
    override_opts = [overwrite_behaviour: overwrite_behaviour, redownload?: is_redownload]

    case MediaDownloader.download_for_media_item(media_item, override_opts) do
      {:ok, downloaded_media_item} ->
        finish_download(media_item, downloaded_media_item, is_quality_upgrade, is_redownload)

      # The download completed after recovering from an error (eg: by retrying without SponsorBlock),
      # so it's finished like any other. The error is kept in the media item's `last_error`
      {:recovered, downloaded_media_item, _message} ->
        finish_download(media_item, downloaded_media_item, is_quality_upgrade, is_redownload)

      {:error, :unsuitable_for_download, _message} ->
        {:ok, :non_retry}

      {:error, _error_atom, message} ->
        action_on_error(message)
    end
  end

  defp finish_download(media_item, downloaded_media_item, is_quality_upgrade, is_redownload) do
    {:ok, updated_media_item} =
      Media.update_media_item(downloaded_media_item, %{
        media_size_bytes: compute_media_filesize(downloaded_media_item),
        media_redownloaded_at: get_redownloaded_at(downloaded_media_item, is_quality_upgrade, is_redownload)
      })

    :ok = FileSyncing.delete_outdated_files(media_item, updated_media_item)
    run_user_script(:media_downloaded, updated_media_item)

    :ok
  end

  defp compute_media_filesize(media_item) do
    case File.stat(media_item.media_filepath) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  # Only quality upgrades set this, and it stops media from being upgraded again. A redownload of existing
  # media doesn't overwrite the existing media file so it keeps the current value. Other downloads clear it
  defp get_redownloaded_at(_media_item, true = _is_quality_upgrade, _is_redownload), do: DateTime.utc_now()
  defp get_redownloaded_at(media_item, _is_quality_upgrade, true = _is_redownload), do: media_item.media_redownloaded_at
  defp get_redownloaded_at(_media_item, _is_quality_upgrade, _is_redownload), do: nil

  defp action_on_error(message) do
    # This will attempt re-download at the next indexing, but it won't be retried
    # immediately as part of job failure logic
    non_retryable_errors = [
      "Video unavailable",
      "Sign in to confirm",
      "This video is available to this channel's members"
    ]

    if String.contains?(to_string(message), non_retryable_errors) do
      Logger.error("yt-dlp download will not be retried: #{inspect(message)}")

      {:ok, :non_retry}
    else
      {:error, :download_failed}
    end
  end

  # NOTE: I like this pattern of using the default value so that I don't have to
  # define it in config.exs (and friends). Consider using this elsewhere.
  defp run_user_script(event, media_item) do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)

    runner.run(event, media_item)
  end
end
