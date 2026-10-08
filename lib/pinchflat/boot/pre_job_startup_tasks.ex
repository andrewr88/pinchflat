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

  # How long startup waits for the app_init user script (see `run_app_init_script/1`).
  # Tests can shorten it with an `:app_init_timeout_ms` key in the state passed to `init/1`
  @app_init_timeout_ms 60_000

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
    run_app_init_script(Map.get(state, :app_init_timeout_ms, @app_init_timeout_ms))

    {:ok, state}
  end

  # Commands run in the tmpfile directory and yt-dlp loads a `yt-dlp.conf` from it, so anyone else
  # who could write to it could make yt-dlp run their own commands. The app won't start if it can't
  # be made private
  defp ensure_tmpfile_directory do
    tmpfile_dir = Application.get_env(:pinchflat, :tmpfile_directory)

    case FilesystemUtils.ensure_private_directory(tmpfile_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        message = """
        The tmpfile directory #{tmpfile_dir} can't be made private to the user Pinchflat runs as: \
        #{describe_tmpfile_directory_error(reason)}. yt-dlp runs in it and loads any yt-dlp.conf in it, \
        so Pinchflat won't start until it's private. The directory only holds temporary files: delete it \
        (or fix its owner) and restart, or set TMPFILE_PATH to a directory owned by Pinchflat's user.
        """

        Logger.error(message)
        raise message
    end
  end

  defp describe_tmpfile_directory_error({:owned_by, uid}), do: "it's owned by another user (uid #{uid})"
  defp describe_tmpfile_directory_error(reason), do: :file.format_error(reason)

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
    # cookies.txt holds browser session credentials, so only the app's user should be able to read it
    files = [
      {"cookies.txt", &FilesystemUtils.write_private_file/2},
      {"yt-dlp-configs/base-config.txt", &FilesystemUtils.write_p/2}
    ]

    base_dir = Application.get_env(:pinchflat, :extras_directory)

    Enum.each(files, fn {file, write_fun} ->
      filepath = Path.join(base_dir, file)

      if !File.exists?(filepath) do
        Logger.info("Creating blank file: #{filepath}")

        :ok = write_fun.(filepath, "")
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

  # Jobs and the web server only start once this returns, and some users rely on the app_init script
  # finishing first, so startup waits for it. But only for so long (60 seconds): a script that hangs, or
  # that starts a background process without redirecting its output (the script only counts as finished
  # once its output is closed), would otherwise stop the app from ever starting.
  #
  # The script isn't stopped once the wait is over. Some users start long-running processes from it, and
  # the command wrapper kills the script and everything it started if the process running it goes away. So
  # it runs in a process of its own that isn't linked to this one: it outlives the wait, and it can't stop
  # the app from starting if it crashes. Its result is logged when it finishes, like any other command's.
  defp run_app_init_script(timeout_ms) do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)
    {:ok, pid} = Task.start(fn -> runner.run(:app_init, %{}) end)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])

        Logger.warning(
          "The app_init user script at #{UserScriptRunner.lifecycle_filepath()} is still running after " <>
            "#{div(timeout_ms, 1_000)} seconds; continuing startup without waiting for it. If it starts a " <>
            "background process, redirect that process's output (eg: `my-daemon > /dev/null 2>&1 &`) so the " <>
            "script can finish."
        )
    end
  end

  defp yt_dlp_runner do
    Application.get_env(:pinchflat, :yt_dlp_runner)
  end

  defp apprise_runner do
    Application.get_env(:pinchflat, :apprise_runner)
  end
end
