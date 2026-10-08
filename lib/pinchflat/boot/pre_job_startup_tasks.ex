defmodule Pinchflat.Boot.PreJobStartupTasks do
  @moduledoc """
  This module is responsible for running startup tasks on app boot
  BEFORE the job runner has initiallized.

  It's a GenServer because that plays REALLY nicely with the existing
  Phoenix supervision tree.
  """

  # restart: :temporary means that this process will never be restarted (ie: will run once and then die)
  use GenServer, restart: :temporary
  import Ecto.Query, warn: false
  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Utils.FilesystemUtils

  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{env: Application.get_env(:pinchflat, :env)}, opts)
  end

  @doc """
  Runs application startup tasks.

  Any code defined here will run every time the application starts. You must
  make sure that the code is idempotent and safe to run multiple times.

  This is a good place to set up default settings, create initial records, stuff like that.
  Should be fast - anything with the potential to be slow should be kicked off as a job instead.
  """
  @impl true
  def init(%{env: :test} = state) do
    # Do nothing _as part of the app bootup process_.
    # Since bootup calls `start_link` and that's where the `env` state is injected,
    # you can still call `.init()` manually to run these tasks for testing purposes
    {:ok, state}
  end

  def init(state) do
    ensure_tmpfile_directory()
    reset_executing_jobs()
    create_blank_yt_dlp_files()
    create_blank_user_script_file()
    apply_default_settings()
    run_app_init_script()

    {:ok, state}
  end

  defp ensure_tmpfile_directory do
    tmpfile_dir = Application.get_env(:pinchflat, :tmpfile_directory)

    if !File.exists?(tmpfile_dir) do
      File.mkdir_p!(tmpfile_dir)
    end
  end

  # If a node cannot gracefully shut down, the currently executing jobs get stuck
  # in the "executing" state. This is a problem because the job runner will not
  # pick them up again
  defp reset_executing_jobs do
    {count, _} =
      Oban.Job
      |> where(state: "executing")
      |> where([j], j.attempt < j.max_attempts)
      |> Repo.update_all(set: [state: "retryable"])

    Logger.info("Reset #{count} executing jobs")

    discard_jobs_with_no_attempts_left()
  end

  # The job runner only runs jobs that have attempts left, so an executing job without any
  # would be stuck if it were reset (as older versions did) and would stop a unique job like it
  # being queued (eg: a source's next directory update). It's discarded instead, like a job
  # that fails on its last attempt
  defp discard_jobs_with_no_attempts_left do
    now = DateTime.utc_now()

    jobs =
      Oban.Job
      |> where([j], j.state in ["executing", "available", "scheduled", "retryable"])
      |> where([j], j.attempt >= j.max_attempts)
      |> Repo.all()

    Enum.each(jobs, fn job ->
      error = %{
        attempt: job.attempt,
        at: now,
        error: "The app stopped while this job was running, with no attempts left"
      }

      job
      |> Ecto.Changeset.change(state: "discarded", discarded_at: now, errors: job.errors ++ [error])
      |> Repo.update!()
    end)

    Logger.info("Discarded #{length(jobs)} interrupted jobs with no attempts left")
  end

  defp create_blank_yt_dlp_files do
    files = ["cookies.txt", "yt-dlp-configs/base-config.txt"]
    base_dir = Application.get_env(:pinchflat, :extras_directory)

    Enum.each(files, fn file ->
      filepath = Path.join(base_dir, file)

      if !File.exists?(filepath) do
        Logger.info("Creating blank file: #{filepath}")

        FilesystemUtils.write_p!(filepath, "")
      end
    end)
  end

  defp create_blank_user_script_file do
    base_dir = Application.get_env(:pinchflat, :extras_directory)
    filepath = Path.join([base_dir, "user-scripts", "lifecycle"])

    if !File.exists?(filepath) do
      Logger.info("Creating blank file and making it executable: #{filepath}")

      FilesystemUtils.write_p!(filepath, "")
      File.chmod(filepath, 0o755)
    end
  end

  defp apply_default_settings do
    apply_version_setting(:yt_dlp_version, yt_dlp_runner())
    apply_version_setting(:apprise_version, apprise_runner())
  end

  # The versions are only displayed in the UI, so failing to fetch one (eg: a broken
  # executable) mustn't stop the app from booting. The stored version is kept instead
  defp apply_version_setting(setting_name, runner) do
    case fetch_version(runner) do
      {:ok, version} ->
        Settings.set([{setting_name, version}])

      {:error, reason} ->
        Logger.warning("Could not fetch #{setting_name}, keeping the stored value: #{inspect(reason)}")
    end
  end

  # An executable that isn't installed is `nil`, which makes `System.cmd/3` raise
  # instead of returning an error
  defp fetch_version(runner) do
    runner.version()
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp run_app_init_script do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)

    runner.run(:app_init, %{})
  end

  defp yt_dlp_runner do
    Application.get_env(:pinchflat, :yt_dlp_runner)
  end

  defp apprise_runner do
    Application.get_env(:pinchflat, :apprise_runner)
  end
end
