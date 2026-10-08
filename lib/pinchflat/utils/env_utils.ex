defmodule Pinchflat.Utils.EnvUtils do
  @moduledoc """
  Utility methods for reading settings from environment variables in `config/runtime.exs`.
  The app's modules are already loaded when that runs, including in a release.

  A variable that isn't set or is empty gets the default. Any other value must be valid,
  otherwise an `ArgumentError` naming the variable and the values it takes is raised. That
  stops the app from starting with a clear message, rather than a cryptic crash or a setting
  that silently isn't what was asked for (eg: "5x" taken as 5).
  """

  @log_levels ~w(debug info notice warning error critical alert emergency all none)a

  @doc """
  Gets an environment variable's whole number greater than 0, or the default.

  Returns integer() | raises ArgumentError
  """
  def get_positive_integer!(name, default) do
    get_integer!(name, default, &(&1 > 0), "a whole number greater than 0")
  end

  @doc """
  Gets an environment variable's port number (1 to 65535), or the default.

  Returns integer() | raises ArgumentError
  """
  def get_port!(name, default) do
    get_integer!(name, default, &(&1 in 1..65_535), "a whole number from 1 to 65535")
  end

  @doc """
  Gets an environment variable's `Logger` level (in any case), or the default. Like
  `Logger`, `warn` is taken as `warning`.

  Returns atom() | raises ArgumentError
  """
  def get_log_level!(name, default) do
    case get_env(name) do
      nil -> default
      value -> parse_log_level(value) || raise_invalid!(name, value, "one of #{Enum.join(@log_levels, ", ")}")
    end
  end

  defp get_integer!(name, default, valid?, description) do
    case get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {integer, ""} -> if valid?.(integer), do: integer, else: raise_invalid!(name, value, description)
          _ -> raise_invalid!(name, value, description)
        end
    end
  end

  defp parse_log_level(value) do
    case String.downcase(value) do
      "warn" -> :warning
      level -> Enum.find(@log_levels, &(Atom.to_string(&1) == level))
    end
  end

  # An empty variable (eg: `PORT=` in a compose file) is taken as not set
  defp get_env(name) do
    case System.get_env(name) do
      "" -> nil
      value -> value
    end
  end

  defp raise_invalid!(name, value, description) do
    raise ArgumentError, "#{name} is set to #{inspect(value)}, but it must be #{description}"
  end
end
