defmodule Pinchflat.Boot.PreJobStartupTasksTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog
  import Pinchflat.JobFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings
  alias Pinchflat.Boot.PreJobStartupTasks
  alias Pinchflat.JobFixtures.TestJobWorker
  alias Pinchflat.Sources.SourceDirectoryUpdateWorker

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
      expect(UserScriptRunnerMock, :run, fn :app_init, data ->
        assert data == %{}

        {:ok, "", 0}
      end)

      PreJobStartupTasks.init(%{})
    end
  end

  defp job_fixture_in_state(state, attempt: attempt, max_attempts: max_attempts) do
    {:ok, job} = Oban.insert(TestJobWorker.new(%{}, max_attempts: max_attempts))
    Repo.update_all(where(Oban.Job, id: ^job.id), set: [state: state, attempt: attempt])

    job
  end
end
