defmodule Pinchflat.Boot.PreJobStartupTasksTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog
  import Pinchflat.JobFixtures

  alias Pinchflat.Settings
  alias Pinchflat.Boot.PreJobStartupTasks

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
end
