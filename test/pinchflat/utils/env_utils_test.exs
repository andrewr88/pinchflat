defmodule Pinchflat.Utils.EnvUtilsTest do
  # Environment variables are global
  use ExUnit.Case, async: false

  alias Pinchflat.Utils.EnvUtils

  @name "PINCHFLAT_ENV_UTILS_TEST"

  setup do
    on_exit(fn -> System.delete_env(@name) end)
  end

  describe "get_positive_integer!/2" do
    test "returns the variable's value" do
      for {value, expected} <- [{"1", 1}, {"5", 5}, {"64", 64}] do
        System.put_env(@name, value)

        assert EnvUtils.get_positive_integer!(@name, 2) == expected
      end
    end

    test "returns the default if the variable is unset or empty" do
      assert EnvUtils.get_positive_integer!(@name, 2) == 2

      System.put_env(@name, "")

      assert EnvUtils.get_positive_integer!(@name, 2) == 2
    end

    test "raises an error naming the variable and the values it takes for anything else" do
      for value <- ["abc", "5x", "1.5", " 5", "0", "-1"] do
        System.put_env(@name, value)
        message = "#{@name} is set to #{inspect(value)}, but it must be a whole number greater than 0"

        assert_raise ArgumentError, message, fn -> EnvUtils.get_positive_integer!(@name, 2) end
      end
    end
  end

  describe "get_port!/2" do
    test "returns the variable's value" do
      for {value, expected} <- [{"1", 1}, {"8945", 8945}, {"65535", 65_535}] do
        System.put_env(@name, value)

        assert EnvUtils.get_port!(@name, 4000) == expected
      end
    end

    test "returns the default if the variable is unset or empty" do
      assert EnvUtils.get_port!(@name, 4000) == 4000

      System.put_env(@name, "")

      assert EnvUtils.get_port!(@name, 4000) == 4000
    end

    test "raises an error naming the variable and the values it takes for anything else" do
      for value <- ["abc", "80a", "0", "-80", "65536"] do
        System.put_env(@name, value)
        message = "#{@name} is set to #{inspect(value)}, but it must be a whole number from 1 to 65535"

        assert_raise ArgumentError, message, fn -> EnvUtils.get_port!(@name, 4000) end
      end
    end
  end

  describe "get_log_level!/2" do
    test "returns the variable's level, whatever its case" do
      cases = [
        {"debug", :debug},
        {"INFO", :info},
        {"Notice", :notice},
        {"warning", :warning},
        {"error", :error},
        {"critical", :critical},
        {"alert", :alert},
        {"emergency", :emergency},
        {"all", :all},
        {"none", :none}
      ]

      for {value, expected} <- cases do
        System.put_env(@name, value)

        assert EnvUtils.get_log_level!(@name, :debug) == expected
      end
    end

    # Logger still takes it, so it may well be in use
    test "takes the deprecated warn level as warning" do
      System.put_env(@name, "warn")

      assert EnvUtils.get_log_level!(@name, :debug) == :warning
    end

    test "returns the default if the variable is unset or empty" do
      assert EnvUtils.get_log_level!(@name, :debug) == :debug

      System.put_env(@name, "")

      assert EnvUtils.get_log_level!(@name, :debug) == :debug
    end

    test "raises an error naming the variable and the values it takes for anything else" do
      for value <- ["verbose", "information", " info", "0"] do
        System.put_env(@name, value)

        message =
          "#{@name} is set to #{inspect(value)}, but it must be one of " <>
            "debug, info, notice, warning, error, critical, alert, emergency, all, none"

        assert_raise ArgumentError, message, fn -> EnvUtils.get_log_level!(@name, :debug) end
      end
    end
  end

  describe "get_secret_key_base!/2" do
    # The shortest key Phoenix takes
    @key String.duplicate("k", 64)

    setup do
      directory =
        Path.join(Application.get_env(:pinchflat, :tmpfile_directory), "env-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(directory) end)

      %{filepath: Path.join(directory, "secret_key_base")}
    end

    test "returns the variable's value without storing a key", %{filepath: filepath} do
      System.put_env(@name, @key)

      assert EnvUtils.get_secret_key_base!(@name, filepath) == @key
      refute File.exists?(filepath)
    end

    test "returns the key stored in the file if the variable is unset or empty", %{filepath: filepath} do
      # eg: written with `echo`
      write_key_file!(filepath, @key <> "\n")

      assert EnvUtils.get_secret_key_base!(@name, filepath) == @key

      System.put_env(@name, "")

      assert EnvUtils.get_secret_key_base!(@name, filepath) == @key
    end

    test "generates a key if there's no file, storing it in one only its owner can access", %{filepath: filepath} do
      key = EnvUtils.get_secret_key_base!(@name, filepath)

      assert byte_size(key) >= 64
      assert File.read!(filepath) == key
      assert File.stat!(filepath).mode == 0o100600
      assert File.ls!(Path.dirname(filepath)) == ["secret_key_base"]
      assert EnvUtils.get_secret_key_base!(@name, filepath) == key
    end

    test "generates a different key for every file", %{filepath: filepath} do
      other_filepath = Path.join(Path.dirname(filepath), "other_secret_key_base")

      assert EnvUtils.get_secret_key_base!(@name, filepath) != EnvUtils.get_secret_key_base!(@name, other_filepath)
    end

    test "generates a key in place of an empty file", %{filepath: filepath} do
      write_key_file!(filepath, "")
      File.chmod!(filepath, 0o644)

      key = EnvUtils.get_secret_key_base!(@name, filepath)

      assert byte_size(key) >= 64
      assert File.read!(filepath) == key
      assert File.stat!(filepath).mode == 0o100600
    end

    # Replacing the key would invalidate existing sessions, so the file is left for the user to fix
    test "raises an error naming the file if its key is too short, leaving it as-is", %{filepath: filepath} do
      short_key = String.duplicate("k", 63)
      write_key_file!(filepath, short_key)

      assert_raise RuntimeError, ~r/#{Regex.escape(filepath)}/, fn -> EnvUtils.get_secret_key_base!(@name, filepath) end
      assert File.read!(filepath) == short_key
    end
  end

  defp write_key_file!(filepath, contents) do
    File.mkdir_p!(Path.dirname(filepath))
    File.write!(filepath, contents)
  end
end
