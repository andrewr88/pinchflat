defmodule Pinchflat.SlowIndexing.MediaCollectionIndexingWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :media_collection_indexing,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable]],
    tags: ["media_source", "media_collection_indexing", "show_in_dashboard"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Settings
  alias Pinchflat.Sources.Source
  alias Pinchflat.FastIndexing.FastIndexingWorker
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.Lifecycle.Notifications.SourceNotifications

  @doc """
  Starts the source slow indexing worker and creates a task for the source.

  Returns {:ok, %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(source, job_args \\ %{}, job_opts \\ []) do
    %{id: source.id}
    |> Map.merge(job_args)
    |> MediaCollectionIndexingWorker.new(job_opts)
    |> Tasks.create_job_with_task(source)
  end

  @doc """
  The ID is that of a source _record_, not a YouTube channel/playlist ID. Indexes
  the provided source, kicks off downloads for each new MediaItem, and
  reschedules the job to run again in the future. It will ALWAYS index a source
  if it's never been indexed before or if `force` is set to `true`, but rescheduling
  is determined by the `index_frequency_minutes` field. A disabled source isn't
  indexed (or rescheduled) at all, even if `force` is set.

  README: Re-scheduling here works a little different than you may expect.
  The reschedule time is relative to the time the job has actually _completed_.
  This has some benefits but also side effects to be aware of:

  - Benefit: No chance for jobs to overlap if a job takes longer than the
    scheduled interval. Less likely to hit API rate limits.
  - Side effect: Intervals are "soft" and _always_ walk forward. This may cause
    user confusion since a 30-minute job scheduled for every hour will
    actually run every 1 hour and 30 minutes. The tradeoff of not inundating
    the API with requests and also not overlapping jobs is worth it, IMO.

  Order of operations:
    1. The user saves a source
    2. This job is automatically scheduled immediately. This happens in all cases.
    3. This job indexes all content for the given source. A download job is
       enqueued for each media item that should be downloaded. This can be impacted
       by the `download_media` field on the source as well as the profile's
       shorts/livestream behaviour. At this step we also attach a file reader
       to the `yt-dlp` output file so we can create media items as they come in
       for a little speedup (see {Fast,Slow}IndexingHelpers comments for more)
    4. If this job is meant to reschedule (ie: has an index frequency > 0),
       it reschedules itself (even if indexing failed). If not, it runs once and
       does not reschedule. If that one run fails (including yt-dlp only partially
       indexing a source for the first time, see `SlowIndexingHelpers`), Oban retries it
    5. If the source uses fast indexing, that job is kicked off as well. It
       uses RSS to run a smaller, faster, and more frequent index. That job
       handles rescheduling itself but largely has a similar behaviour to this
       job in that it runs and index and maybe kicks off media download jobs.
       Check out `FastIndexingWorker` comments for more.
    6. If the job reschedules, the cycle from step 3 repeats until the heat death
       of the universe. The user changing things like the index frequency can
       dequeue or reschedule jobs as well

  NOTE: Since indexing can take a LONG time, I should check what happens if an
  application restart occurs while a job is running. Will the job be lost?

  Returns :ok | {:ok, %Task{}} | {:ok, :job_exists} | {:error, :indexing_failed} | {:error, :indexing_incomplete}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => source_id} = args}) do
    source_id
    |> Sources.get_source!()
    |> index_source(args)
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: source #{source_id} not found")
    Ecto.StaleEntryError -> Logger.info("#{__MODULE__} discarded: source #{source_id} stale")
  end

  # Disabling a source deletes its indexing jobs but one can still turn up, eg: if it's forced.
  # Indexing would also schedule the next index, so the source would be indexed from then on
  defp index_source(%Source{enabled: false}, _args), do: :ok

  defp index_source(source, args) do
    case {source.index_frequency_minutes, source.last_indexed_at} do
      {index_freq, _} when index_freq > 0 ->
        # If the indexing is on a schedule simply run indexing and reschedule. This
        # reschedules even if indexing failed so the source keeps its normal schedule
        # (failing the job here would also leave an Oban retry next to the new job)
        perform_indexing_and_notification(source, was_forced: args["force"])
        maybe_enqueue_fast_indexing_task(source)
        reschedule_indexing(source)

      {_, nil} ->
        # If the source has never been indexed, index it once
        # even if it's not meant to reschedule
        source
        |> perform_indexing_and_notification(was_forced: args["force"])
        |> to_job_result()

      _ ->
        # If the source HAS been indexed and is not meant to reschedule,
        # perform a no-op (unless forced)
        if args["force"] do
          source
          |> perform_indexing_and_notification(was_forced: true)
          |> to_job_result()
        else
          :ok
        end
    end
  end

  # Nothing reschedules a one-off index so return failures to Oban, letting it retry them
  defp to_job_result({:error, reason}), do: {:error, reason}
  defp to_job_result(_media_items), do: :ok

  # Only the media items this index created are counted. A fast index can create some of the same
  # media while this runs (eg: they're both kicked off when a source is created) and it sends its own
  # notification for those
  defp perform_indexing_and_notification(source, indexing_opts) do
    apprise_server = Settings.get!(:apprise_server)
    notify = &SourceNotifications.send_new_media_notification_for_media_items(apprise_server, source, &1)
    opts = Keyword.put(indexing_opts, :on_new_media_items, notify)

    SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source, opts)
  end

  defp reschedule_indexing(source) do
    next_run_in = source.index_frequency_minutes * 60

    %{id: source.id}
    |> MediaCollectionIndexingWorker.new(schedule_in: next_run_in)
    |> Tasks.create_job_with_task(source)
    |> case do
      {:ok, task} -> {:ok, task}
      {:error, :duplicate_job} -> {:ok, :job_exists}
    end
  end

  defp maybe_enqueue_fast_indexing_task(source) do
    if source.fast_index do
      Tasks.delete_pending_tasks_for(source, "FastIndexingWorker")

      next_run_in = Source.fast_index_frequency() * 60

      %{id: source.id}
      |> FastIndexingWorker.new(schedule_in: next_run_in)
      |> Tasks.create_job_with_task(source)
    end
  end
end
