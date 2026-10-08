defmodule Pinchflat.Utils.CliUtilsTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog

  alias Pinchflat.Utils.CliUtils
  alias Pinchflat.Utils.FilesystemUtils

  describe "wrap_cmd/3" do
    test "delegates to System.cmd/3" do
      assert {"output\n", 0} = CliUtils.wrap_cmd("echo", ["output"])
    end

    test "sets the current directory to the tmp dir" do
      assert {"/tmp/test/tmpfiles\n", 0} = CliUtils.wrap_cmd("pwd", [])
    end

    # `System.find_executable/1` returns nil for executables that aren't installed
    test "returns a not found exit status instead of raising when the command is nil" do
      assert {"executable not found", 127} = CliUtils.wrap_cmd(nil, ["--version"])
    end

    test "respects the logging override when the command is nil" do
      # The test env only logs critical messages so let the command logging through
      Logger.put_module_level(CliUtils, :all)
      on_exit(fn -> Logger.delete_module_level(CliUtils) end)

      log = capture_log(fn -> CliUtils.wrap_cmd(nil, ["secret-arg"], [], logging_arg_override: "[suppressed]") end)

      assert log =~ "[error]"
      assert log =~ "executable not found"
      assert log =~ "[suppressed]"
      refute log =~ "secret-arg"
    end

    test "returns the command's exit status" do
      assert {_, 0} = CliUtils.wrap_cmd("bash", ["-c", "exit 0"])
      assert {_, 2} = CliUtils.wrap_cmd("bash", ["-c", "exit 2"])
    end

    test "returns 126 if the command isn't executable" do
      filepath = write_script("#!/bin/sh\nexit 0\n", 0o644)

      assert {_, 126} = CliUtils.wrap_cmd(filepath, [], stderr_to_stdout: true)
    end

    test "returns 127 if the command's interpreter is missing" do
      filepath = write_script("#!/nonexistent/interpreter\nexit 0\n", 0o755)

      assert {_, 127} = CliUtils.wrap_cmd(filepath, [], stderr_to_stdout: true)
    end

    test "returns 128 + the signal's number if the command is killed" do
      assert {_, 137} = CliUtils.wrap_cmd("bash", ["-c", "kill -KILL $$"])
    end
  end

  describe "wrap_cmd/3 when the caller is killed" do
    # Cancelling a job kills the process running the command, which closes the command's stdin
    test "kills the command and any processes it started" do
      pids_filepath = Path.join(tmpfile_directory(), "pids-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(pids_filepath) end)

      # The grandchild stops by itself if it survives. The pids are written in one go so they're never read half-written
      script = """
      sleep 30 >/dev/null 2>&1 &
      echo "$$ $!" > #{pids_filepath}.tmp && mv #{pids_filepath}.tmp #{pids_filepath}
      wait
      """

      task = Task.async(fn -> CliUtils.wrap_cmd("bash", ["-c", script]) end)

      assert [_command_pid, _grandchild_pid] = os_pids = eventually(fn -> read_pids(pids_filepath) end)
      assert Enum.all?(os_pids, &os_process_alive?/1)

      Task.shutdown(task, :brutal_kill)

      assert eventually(fn -> !Enum.any?(os_pids, &os_process_alive?/1) end)
    end
  end

  describe "parse_options/1" do
    test "it converts symbol k-v arg keys to kebab case" do
      assert ["--buffer-size", "1024"] = CliUtils.parse_options(buffer_size: 1024)
    end

    test "it keeps string k-v arg keys untouched" do
      assert ["--under_score", "1024"] = CliUtils.parse_options({"--under_score", 1024})
    end

    test "it converts symbol arg keys to kebab case" do
      assert ["--ignore-errors"] = CliUtils.parse_options(:ignore_errors)
    end

    test "it keeps string arg keys untouched" do
      assert ["-v"] = CliUtils.parse_options("-v")
    end

    test "it keeps the options in order, converting each one" do
      cases = [
        # Flags and options with values are mixed
        {[:a, {:b, 1}, "c", {"--d", "x"}, {:b, 2}], ["--a", "--b", "1", "c", "--d", "x", "--b", "2"]},
        # Repeated keys are all kept
        {[parse_metadata: "x", parse_metadata: "y"], ["--parse-metadata", "x", "--parse-metadata", "y"]},
        # Atom keys are kebab-cased, string keys aren't
        {[:no_mtime, "--no_mtime", {:sleep_interval, 1}, {"--sleep_interval", 1}],
         ["--no-mtime", "--no_mtime", "--sleep-interval", "1", "--sleep_interval", "1"]},
        # Values are converted to strings
        {[limit_rate: 1.5, retries: 3, format: :best, overwrites: true],
         ["--limit-rate", "1.5", "--retries", "3", "--format", "best", "--overwrites", "true"]}
      ]

      for {options, expected} <- cases do
        assert CliUtils.parse_options(options) == expected
      end
    end
  end

  defp tmpfile_directory do
    Application.get_env(:pinchflat, :tmpfile_directory)
  end

  defp write_script(contents, mode) do
    filepath = Path.join(tmpfile_directory(), "script-#{System.unique_integer([:positive])}")
    FilesystemUtils.write_p!(filepath, contents)
    File.chmod!(filepath, mode)
    on_exit(fn -> File.rm(filepath) end)

    filepath
  end

  defp read_pids(filepath) do
    case File.read(filepath) do
      {:ok, contents} -> contents |> String.split() |> Enum.map(&String.to_integer/1)
      {:error, _} -> nil
    end
  end

  # A killed process is a zombie until it's reaped, which might never happen if its parent died too
  defp os_process_alive?(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", to_string(os_pid)]) do
      {stat, 0} -> !String.starts_with?(String.trim(stat), "Z")
      _ -> false
    end
  end

  # Polls the function until it returns a truthy value, which is returned. Returns nil if it times out
  defp eventually(fun, timeout_ms \\ 5_000) do
    poll_until(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp poll_until(fun, deadline) do
    result = fun.()

    cond do
      result ->
        result

      System.monotonic_time(:millisecond) > deadline ->
        nil

      true ->
        Process.sleep(20)
        poll_until(fun, deadline)
    end
  end
end
