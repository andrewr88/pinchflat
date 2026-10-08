defmodule Pinchflat.Boot.PreJobStartupTasksTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog
  import Pinchflat.JobFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Boot.PreJobStartupTasks
  alias Pinchflat.JobFixtures.TestJobWorker
  alias Pinchflat.Sources.SourceDirectoryUpdateWorker
  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner

  setup do
    stub(YtDlpRunnerMock, :version, fn -> {:ok, "1"} end)
    stub(AppriseRunnerMock, :version, fn -> {:ok, "2"} end)
    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "3", 0} end)

    :ok
  end

  describe "ensure_tmpfile_directory" do
    test "creates the tmpfile directory if it doesn't exist" do
      tmpfile_dir = Application.get_env(:pinchflat, :tmpfile_directory)
      File.rm_rf!(tmpfile_dir)

      refute File.exists?(tmpfile_dir)

      PreJobStartupTasks.init(%{})

      assert File.exists?(tmpfile_dir)
    end

    # Commands run in it and yt-dlp loads a `yt-dlp.conf` from it, so nobody else should be able to write to it
    test "makes a new tmpfile directory accessible only by the app's user" do
      tmpfile_dir = Application.get_env(:pinchflat, :tmpfile_directory)
      File.rm_rf!(tmpfile_dir)

      PreJobStartupTasks.init(%{})

      assert File.stat!(tmpfile_dir).mode == 0o40700
    end

    test "makes an existing tmpfile directory accessible only by the app's user" do
      tmpfile_dir = Application.get_env(:pinchflat, :tmpfile_directory)
      File.chmod!(tmpfile_dir, 0o777)

      PreJobStartupTasks.init(%{})

      assert File.stat!(tmpfile_dir).mode == 0o40700
    end

    test "refuses to start if the tmpfile directory can't be made private" do
      # The test env only logs critical messages so let this module's logging through
      Logger.put_module_level(PreJobStartupTasks, :all)
      tmpfile_dir = Application.get_env(:pinchflat, :tmpfile_directory)
      File.rm_rf!(tmpfile_dir)
      File.write!(tmpfile_dir, "not a directory")

      on_exit(fn ->
        Logger.delete_module_level(PreJobStartupTasks)
        File.rm(tmpfile_dir)
        File.mkdir_p(tmpfile_dir)
      end)

      log =
        capture_log([level: :error], fn ->
          assert_raise RuntimeError, ~r/tmpfile directory/, fn -> PreJobStartupTasks.init(%{}) end
        end)

      assert log =~ tmpfile_dir
    end
  end

  describe "reset_executing_jobs" do
    test "resets executing jobs" do
      job = job_fixture()
      Repo.update_all(Oban.Job, set: [state: "executing"])

      assert Repo.reload!(job).state == "executing"

      PreJobStartupTasks.init(%{})

      assert Repo.reload!(job).state == "retryable"
    end

    # The job runner only runs jobs with attempts left, so a retryable one would be stuck forever
    test "discards executing jobs that have no attempts left" do
      job = job_fixture_in_state("executing", attempt: 1, max_attempts: 1)

      PreJobStartupTasks.init(%{})

      job = Repo.reload!(job)
      assert job.state == "discarded"
      assert job.discarded_at
      assert [%{"attempt" => 1, "error" => error}] = job.errors
      assert error =~ "app stopped while this job was running"
    end

    test "discards jobs an earlier restart left stuck with no attempts left" do
      job = job_fixture_in_state("available", attempt: 1, max_attempts: 1)

      PreJobStartupTasks.init(%{})

      assert Repo.reload!(job).state == "discarded"
    end

    test "leaves jobs that haven't run alone" do
      job = job_fixture_in_state("available", attempt: 0, max_attempts: 1)

      PreJobStartupTasks.init(%{})

      assert Repo.reload!(job).state == "available"
    end

    test "leaves finished jobs alone, even if they have no attempts left" do
      jobs =
        for state <- ["completed", "cancelled", "discarded"] do
          job_fixture_in_state(state, attempt: 1, max_attempts: 1)
        end

      PreJobStartupTasks.init(%{})

      assert Enum.map(jobs, &Repo.reload!(&1).state) == ["completed", "cancelled", "discarded"]
      assert Enum.all?(jobs, &(Repo.reload!(&1).errors == []))
    end

    test "discards scheduled and retryable jobs that have no attempts left" do
      scheduled_job = job_fixture_in_state("scheduled", attempt: 1, max_attempts: 1)
      retryable_job = job_fixture_in_state("retryable", attempt: 2, max_attempts: 1)

      PreJobStartupTasks.init(%{})

      assert Repo.reload!(scheduled_job).state == "discarded"
      assert Repo.reload!(retryable_job).state == "discarded"
    end

    test "adds the discard reason after a job's existing errors" do
      job = job_fixture_in_state("executing", attempt: 1, max_attempts: 1)
      original_error = %{"attempt" => 1, "at" => "2025-01-01T00:00:00Z", "error" => "original error"}
      Repo.update_all(where(Oban.Job, id: ^job.id), set: [errors: [original_error]])

      PreJobStartupTasks.init(%{})

      assert [^original_error, %{"error" => error}] = Repo.reload!(job).errors
      assert error =~ "app stopped while this job was running"
    end

    # It's only attempted once, and only one directory update per source can be queued or running
    test "lets a source's directory update that was running be queued again" do
      source = source_fixture()
      {:ok, task} = SourceDirectoryUpdateWorker.kickoff_with_task(source)
      Repo.update_all(where(Oban.Job, id: ^task.job_id), set: [state: "executing", attempt: 1])

      PreJobStartupTasks.init(%{})

      assert {:ok, _} = SourceDirectoryUpdateWorker.kickoff_with_task(source)
    end
  end

  describe "create_blank_yt_dlp_files" do
    test "creates a blank cookie file" do
      base_dir = Application.get_env(:pinchflat, :extras_directory)
      filepath = Path.join(base_dir, "cookies.txt")
      File.rm(filepath)

      refute File.exists?(filepath)

      PreJobStartupTasks.init(%{})

      assert File.exists?(filepath)
    end

    # It's where browser session credentials go
    test "makes a new cookie file readable only by the app's user" do
      base_dir = Application.get_env(:pinchflat, :extras_directory)
      filepath = Path.join(base_dir, "cookies.txt")
      File.rm(filepath)

      PreJobStartupTasks.init(%{})

      assert File.stat!(filepath).mode == 0o100600
    end

    test "creates a blank yt-dlp config file" do
      base_dir = Application.get_env(:pinchflat, :extras_directory)
      filepath = Path.join([base_dir, "yt-dlp-configs", "base-config.txt"])
      File.rm(filepath)

      refute File.exists?(filepath)

      PreJobStartupTasks.init(%{})

      assert File.exists?(filepath)
    end
  end

  describe "create_blank_user_script_file" do
    test "creates a blank script file" do
      base_dir = Application.get_env(:pinchflat, :extras_directory)
      filepath = Path.join([base_dir, "user-scripts", "lifecycle"])
      File.rm(filepath)

      refute File.exists?(filepath)

      PreJobStartupTasks.init(%{})

      assert File.exists?(filepath)
    end

    test "gives it 755 permissions" do
      base_dir = Application.get_env(:pinchflat, :extras_directory)
      filepath = Path.join([base_dir, "user-scripts", "lifecycle"])
      File.rm(filepath)

      PreJobStartupTasks.init(%{})

      assert File.stat!(filepath).mode == 0o100755
    end
  end

  describe "create_blank_yt_dlp_files and create_blank_user_script_file" do
    test "leave the user's existing files alone" do
      base_dir = Application.get_env(:pinchflat, :extras_directory)

      files = [
        {Path.join(base_dir, "cookies.txt"), "cookie data", 0o644},
        {Path.join([base_dir, "yt-dlp-configs", "base-config.txt"]), "--no-mtime", 0o644},
        {Path.join([base_dir, "user-scripts", "lifecycle"]), "#!/bin/sh\necho hi\n", 0o700}
      ]

      for {filepath, contents, mode} <- files do
        FilesystemUtils.write_p!(filepath, contents)
        File.chmod!(filepath, mode)
      end

      PreJobStartupTasks.init(%{})

      for {filepath, contents, mode} <- files do
        assert File.read!(filepath) == contents
        assert File.stat!(filepath).mode == 0o100000 + mode
      end
    end
  end

  describe "apply_default_settings" do
    test "sets yt_dlp version" do
      File.rm_rf!(Application.get_env(:pinchflat, :tmpfile_directory))
      Settings.set(yt_dlp_version: nil)

      refute Settings.get!(:yt_dlp_version)

      PreJobStartupTasks.init(%{})

      assert Settings.get!(:yt_dlp_version)
    end

    test "sets apprise version" do
      File.rm_rf!(Application.get_env(:pinchflat, :tmpfile_directory))
      Settings.set(apprise_version: nil)

      refute Settings.get!(:apprise_version)

      PreJobStartupTasks.init(%{})

      assert Settings.get!(:apprise_version)
    end

    test "keeps the stored yt_dlp version if it can't be fetched" do
      stub(YtDlpRunnerMock, :version, fn -> {:error, "boom"} end)
      Settings.set(yt_dlp_version: "2025.09.26")
      Settings.set(apprise_version: nil)

      assert {:ok, _} = PreJobStartupTasks.init(%{})

      assert Settings.get!(:yt_dlp_version) == "2025.09.26"
      assert Settings.get!(:apprise_version) == "2"
    end

    test "keeps the stored apprise version if it can't be fetched" do
      stub(AppriseRunnerMock, :version, fn -> {:error, "boom"} end)
      Settings.set(yt_dlp_version: nil)
      Settings.set(apprise_version: "1.9.4")

      assert {:ok, _} = PreJobStartupTasks.init(%{})

      assert Settings.get!(:yt_dlp_version) == "1"
      assert Settings.get!(:apprise_version) == "1.9.4"
    end

    test "keeps the stored apprise version and finishes booting if apprise isn't installed" do
      # Outside of Docker apprise may not be installed. Its executable is then `nil`, which raises this
      stub(AppriseRunnerMock, :version, fn ->
        raise ArgumentError, "all arguments for System.cmd/3 must be binaries"
      end)

      expect(UserScriptRunnerMock, :run, fn :app_init, _data -> {:ok, "", 0} end)
      Settings.set(apprise_version: "1.9.4")

      assert {:ok, _} = PreJobStartupTasks.init(%{})

      assert Settings.get!(:apprise_version) == "1.9.4"
    end

    test "logs a warning if a version can't be fetched" do
      # The test env only logs critical messages so let this module's logging through
      Logger.put_module_level(PreJobStartupTasks, :all)
      on_exit(fn -> Logger.delete_module_level(PreJobStartupTasks) end)
      stub(YtDlpRunnerMock, :version, fn -> {:error, "boom"} end)

      log = capture_log([level: :warning], fn -> PreJobStartupTasks.init(%{}) end)

      assert log =~ "yt_dlp_version"
      assert log =~ "boom"
    end
  end

  describe "run_app_init_script" do
    test "calls the app_init user script runner" do
      test_pid = self()

      # The runner isn't called from the test's process, so the data is checked here instead
      expect(UserScriptRunnerMock, :run, fn :app_init, data ->
        send(test_pid, {:app_init_data, data})

        {:ok, "", 0}
      end)

      PreJobStartupTasks.init(%{})

      assert_received {:app_init_data, data}
      assert data == %{}
    end

    # Some users rely on it finishing before any jobs run
    test "waits for a script that finishes within the timeout" do
      finished_file = tmpfile_path("app_init_finished")
      write_lifecycle_file("#!/bin/bash\nsleep 0.2\ntouch '#{finished_file}'\necho finished\n")
      expect_real_app_init_run()

      log = capture_warnings(fn -> assert {:ok, _} = PreJobStartupTasks.init(%{app_init_timeout_ms: 5_000}) end)

      assert File.exists?(finished_file)
      assert_received {:app_init_result, {:ok, "finished\n", 0}}
      refute log =~ "still running"
    end

    # Users start long-running processes from it, which stopping it would also stop
    test "stops waiting for a script that's still running after the timeout, but leaves it running" do
      release_file = tmpfile_path("app_init_release")
      write_lifecycle_file("#!/bin/bash\n" <> wait_for_release(release_file))
      expect_real_app_init_run()
      started_at = System.monotonic_time(:millisecond)

      log = capture_warnings(fn -> assert {:ok, _} = PreJobStartupTasks.init(%{app_init_timeout_ms: 300}) end)

      assert System.monotonic_time(:millisecond) - started_at < 5_000
      assert log =~ "The app_init user script at #{UserScriptRunner.lifecycle_filepath()} is still running"

      # It can only finish once it's released, so it was still running when startup carried on
      File.touch!(release_file)
      assert_receive {:app_init_result, result}, 15_000
      assert result == {:ok, "released\n", 0}
    end

    # The script only counts as finished once its output is closed, and the background process has it open
    test "stops waiting for a script whose background process keeps running after the timeout" do
      release_file = tmpfile_path("app_init_release")
      write_lifecycle_file("#!/bin/bash\n(\n#{wait_for_release(release_file)}) &\necho started\n")
      expect_real_app_init_run()

      log = capture_warnings(fn -> assert {:ok, _} = PreJobStartupTasks.init(%{app_init_timeout_ms: 300}) end)

      assert log =~ "still running"

      File.touch!(release_file)
      assert_receive {:app_init_result, result}, 15_000
      assert result == {:ok, "started\nreleased\n", 0}
    end

    test "carries on starting up if running the script crashes" do
      expect(UserScriptRunnerMock, :run, fn :app_init, _data -> raise "boom" end)

      assert {:ok, _} = PreJobStartupTasks.init(%{})
    end
  end

  defp job_fixture_in_state(state, attempt: attempt, max_attempts: max_attempts) do
    {:ok, job} = Oban.insert(TestJobWorker.new(%{}, max_attempts: max_attempts))
    Repo.update_all(where(Oban.Job, id: ^job.id), set: [state: state, attempt: attempt])

    job
  end

  # The user script the real runner runs, removed once the test is done
  defp write_lifecycle_file(contents) do
    filepath = UserScriptRunner.lifecycle_filepath()
    FilesystemUtils.write_p!(filepath, contents)
    File.chmod!(filepath, 0o755)
    on_exit(fn -> File.rm(filepath) end)
  end

  # Runs the real user script, sending its result to the test once it's finished
  defp expect_real_app_init_run do
    test_pid = self()

    expect(UserScriptRunnerMock, :run, fn :app_init, data ->
      result = UserScriptRunner.run(:app_init, data)
      send(test_pid, {:app_init_result, result})

      result
    end)
  end

  # Script lines that wait for the file to exist, then output "released". They give up after 10 seconds
  defp wait_for_release(filepath) do
    """
    for _ in {1..200}; do
      if [ -e '#{filepath}' ]; then echo released; exit 0; fi
      sleep 0.05
    done
    echo 'not released'
    exit 1
    """
  end

  defp tmpfile_path(name) do
    Path.join(Application.get_env(:pinchflat, :tmpfile_directory), "#{name}-#{System.unique_integer([:positive])}")
  end

  defp capture_warnings(fun) do
    # The test env only logs critical messages so let this module's logging through
    Logger.put_module_level(PreJobStartupTasks, :all)
    on_exit(fn -> Logger.delete_module_level(PreJobStartupTasks) end)

    capture_log([level: :warning], fun)
  end
end
