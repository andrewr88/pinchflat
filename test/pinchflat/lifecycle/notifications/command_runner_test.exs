defmodule Pinchflat.Lifecycle.Notifications.CommandRunnerTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog

  alias Pinchflat.Lifecycle.Notifications.CommandRunner, as: Runner
  alias Pinchflat.Utils.CliUtils

  @original_executable Application.compile_env(:pinchflat, :apprise_executable)

  setup do
    on_exit(&reset_executable/0)
  end

  describe "run/2" do
    test "returns :ok when the command succeeds" do
      assert {:ok, _} = Runner.run("server_1", [])
    end

    test "includes the servers as the first argument" do
      assert {:ok, output} = Runner.run(["server_1", "server_2"], [])

      assert String.contains?(output, "server_1 server_2")
    end

    test "lets you pass a single server as a string" do
      assert {:ok, output} = Runner.run("server_1", [])

      assert String.contains?(output, "server_1")
    end

    test "passes all arguments to the command" do
      assert {:ok, output} = Runner.run("server_1", ["--dry-run"])

      assert String.contains?(output, "--dry-run")
    end

    # Otherwise a server like `--config=<url>` would be taken as an apprise option
    test "separates the servers from the options" do
      assert {:ok, output} = Runner.run(["--config=https://example.com/apprise.yml", "server_2"], title: "A title")

      assert output == "--verbose --title A title -- --config=https://example.com/apprise.yml server_2"
    end

    test "returns the output when the command fails" do
      wrap_executable("/bin/false", fn ->
        assert {:error, ""} = Runner.run("server_1", [])
      end)
    end

    test "returns an error if apprise isn't installed" do
      wrap_executable(nil, fn ->
        assert {:error, _} = Runner.run("json://x", title: "t")
      end)
    end

    test "returns a relevant error if no servers are provided" do
      assert {:error, :no_servers} = Runner.run(nil, [])
      assert {:error, :no_servers} = Runner.run("", [])
      assert {:error, :no_servers} = Runner.run([], [])
    end

    test "does not log the servers since they can contain credentials" do
      # The test env only logs critical messages so let the command logging through
      Logger.put_module_level(CliUtils, :all)
      on_exit(fn -> Logger.delete_module_level(CliUtils) end)

      # The default stub echoes its args as output (which is also logged) but apprise
      # doesn't, so use an executable without output to only check the logged args
      wrap_executable("/bin/false", fn ->
        log = capture_log(fn -> Runner.run("tgram://123456:secret-bot-token/987654", title: "A title") end)

        assert log =~ "--title"
        refute log =~ "secret-bot-token"
      end)
    end
  end

  describe "version/0" do
    test "adds the version arg" do
      assert {:ok, output} = Runner.version()

      assert String.contains?(output, "--version")
    end

    test "returns the version from the first line of the output" do
      script = write_script("#!/bin/sh\nprintf 'Apprise v2.0.1\\r\\nPython 3.12.3\\r\\n'\n")

      wrap_executable(script, fn ->
        assert {:ok, "v2.0.1"} = Runner.version()
      end)
    end

    test "returns the output if the command fails" do
      script = write_script("#!/bin/sh\necho 'something went wrong'\nexit 3\n")

      wrap_executable(script, fn ->
        assert {:error, "something went wrong\n"} = Runner.version()
      end)
    end
  end

  defp write_script(contents) do
    tmpfile_directory = Application.get_env(:pinchflat, :tmpfile_directory)
    filepath = Path.join(tmpfile_directory, "apprise-#{System.unique_integer([:positive])}")
    File.write!(filepath, contents)
    File.chmod!(filepath, 0o755)
    on_exit(fn -> File.rm(filepath) end)

    filepath
  end

  defp wrap_executable(new_executable, fun) do
    Application.put_env(:pinchflat, :apprise_executable, new_executable)
    fun.()
    reset_executable()
  end

  def reset_executable do
    Application.put_env(:pinchflat, :apprise_executable, @original_executable)
  end
end
