defmodule Pinchflat.Utils.CliUtilsTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog

  alias Pinchflat.Utils.CliUtils

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
  end
end
