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
end
