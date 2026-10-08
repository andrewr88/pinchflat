defmodule Pinchflat.Profiles.MediaProfileDeletionWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_profiles", "local_data"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Profiles
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Sources.SourceDirectoryUpdateWorker

  # How long to wait before checking again whether the sources' directory updates have finished
  @directory_update_wait_seconds 30

  @doc """
  Starts the profile deletion worker. Does not attach it to a task like `kickoff_with_task/2`
  since deletion also cancels all tasks for the profile

  Returns {:ok, %Oban.Job{}} | {:error, %Ecto.Changeset{}}
  """
  def kickoff(profile, job_args \\ %{}, job_opts \\ []) do
    %{id: profile.id}
    |> Map.merge(job_args)
    |> MediaProfileDeletionWorker.new(job_opts)
    |> Oban.insert()
  end

  @doc """
  Deletes a profile and its sources, and optionally deletes their files.

  Deleting a source cancels its jobs, and cancelling a directory update that's running
  kills it partway through moving the files, leaving them stranded. So this waits for the
  running ones of the profile's sources to finish. Queued ones are just cancelled: they
  haven't moved anything yet. A source added to the profile while it's being deleted
  fails the deletion with an error, so it's retried.

  Returns {:ok, %MediaProfile{}} | {:error, %Ecto.Changeset{}} | {:snooze, integer()} | :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => profile_id} = args}) do
    delete_files = Map.get(args, "delete_files", false)
    profile = Profiles.get_media_profile!(profile_id)

    if Enum.any?(Sources.list_sources_for(profile), &SourceDirectoryUpdateWorker.running_for?/1) do
      {:snooze, @directory_update_wait_seconds}
    else
      Profiles.delete_media_profile(profile, delete_files: delete_files)
    end
  rescue
    Ecto.NoResultsError ->
      Logger.info("#{__MODULE__} discarded: media profile #{profile_id} not found")

    # Another job deleted a record first. If that only took some of the profile's sources
    # or media (eg: the deletion of one of its sources), this is retried to delete the rest
    error in Ecto.StaleEntryError ->
      if Repo.get(MediaProfile, profile_id) do
        reraise error, __STACKTRACE__
      else
        Logger.info("#{__MODULE__} discarded: media profile #{profile_id} stale")
      end
  end
end
