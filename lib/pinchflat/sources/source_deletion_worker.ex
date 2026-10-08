defmodule Pinchflat.Sources.SourceDeletionWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["sources", "local_data"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Sources
  alias Pinchflat.Sources.SourceDirectoryUpdateWorker

  # How long to wait before checking again whether the source's directory update has finished
  @directory_update_wait_seconds 30

  @doc """
  Starts the source deletion worker. Does not attach it to a task like `kickoff_with_task/2`
  since deletion also cancels all tasks for the source

  Returns {:ok, %Task{}} | {:error, %Ecto.Changeset{}}
  """
  def kickoff(source, job_args \\ %{}, job_opts \\ []) do
    %{id: source.id}
    |> Map.merge(job_args)
    |> SourceDeletionWorker.new(job_opts)
    |> Oban.insert()
  end

  @doc """
  Deletes a source and optionally deletes its files.

  Deleting a source cancels its jobs, and cancelling a directory update that's running
  kills it partway through moving the files, leaving them stranded. So this waits for a
  running one to finish. A queued one is just cancelled: it hasn't moved anything yet.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}} | {:snooze, integer()} | :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => source_id} = args}) do
    delete_files = Map.get(args, "delete_files", false)
    source = Sources.get_source!(source_id)

    if SourceDirectoryUpdateWorker.running_for?(source) do
      {:snooze, @directory_update_wait_seconds}
    else
      Sources.delete_source(source, delete_files: delete_files)
    end
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: source #{source_id} not found")
    Ecto.StaleEntryError -> Logger.info("#{__MODULE__} discarded: source #{source_id} stale")
  end
end
