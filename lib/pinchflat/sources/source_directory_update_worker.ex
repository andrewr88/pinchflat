defmodule Pinchflat.Sources.SourceDirectoryUpdateWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["sources", "local_data", "show_in_dashboard"],
    # Never retry a file-moving job automatically. A failed one is just recorded as an error
    max_attempts: 1

  require Logger

  alias __MODULE__
  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources

  @doc """
  Starts the source directory update worker and creates a task for the source.
  Only one update per source can be queued or running at a time.

  Returns {:ok, %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(source, opts \\ []) do
    %{id: source.id}
    |> SourceDirectoryUpdateWorker.new(opts)
    |> Tasks.create_job_with_task(source)
  end

  @doc """
  Returns the source's most recent directory update job in any state, or nil if it has
  none. Oban prunes old jobs, so this only sees jobs from the last 30 days.

  Returns %Oban.Job{} | nil
  """
  def latest_job_for(source) do
    source
    |> Tasks.list_tasks_for("SourceDirectoryUpdateWorker")
    |> Repo.preload(:job)
    |> Enum.map(& &1.job)
    # inserted_at only has second precision, so the ID breaks ties
    |> Enum.max_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}, fn -> nil end)
  end

  @doc """
  Moves a source's files to match its current custom name and output path template
  with `Sources.update_source_directory/1`, which rolls back a failed update itself.
  A failed update's errors (including any files that couldn't be moved back) are
  logged and returned, so Oban records the job as failed.

  Returns :ok | {:error, String.t()}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => source_id}}) do
    source = Sources.get_source!(source_id)

    case Sources.update_source_directory(source) do
      {:ok, _source} ->
        Logger.info("Updated the directory for source ##{source.id} (#{source.custom_name})")

        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        message = format_errors(changeset)
        Logger.error("Error updating the directory for source ##{source.id} (#{source.custom_name}): #{message}")

        {:error, message}
    end
  end

  defp format_errors(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {message, _opts}} -> "#{field}: #{message}" end)
  end
end
