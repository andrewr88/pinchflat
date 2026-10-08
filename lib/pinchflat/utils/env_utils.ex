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
  # The shortest key Phoenix takes
  @secret_key_base_min_length 64

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

  @doc """
  Gets an environment variable's secret key base as-is, or else the key stored in the given file.
  If the file doesn't exist or is empty, a random key is generated and stored in it so the same key
  is used from then on. Only the file's owner can ever read a generated file. A stored key that's too
  short raises a `RuntimeError` naming the file: replacing it would invalidate existing sessions.

  Returns binary() | raises RuntimeError
  """
  def get_secret_key_base!(name, filepath) do
    case get_env(name) do
      nil -> read_or_generate_secret_key_base!(filepath)
      value -> value
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

  defp read_or_generate_secret_key_base!(filepath) do
    case File.read(filepath) do
      {:ok, contents} ->
        stored_secret_key_base!(String.trim(contents), filepath)

      {:error, :enoent} ->
        generate_secret_key_base!(filepath)

      {:error, reason} ->
        raise "Can't read the secret key base in #{filepath}: #{:file.format_error(reason)}. Make sure " <>
                "the user Pinchflat runs as can read it, or set SECRET_KEY_BASE"
    end
  end

  # An empty file (eg: made with `touch`) is taken as not there
  defp stored_secret_key_base!("", filepath), do: generate_secret_key_base!(filepath)

  defp stored_secret_key_base!(key, filepath) do
    if String.length(key) >= @secret_key_base_min_length do
      key
    else
      raise "The secret key base in #{filepath} is too short: it must be at least " <>
              "#{@secret_key_base_min_length} characters. Delete the file to have a new key generated, " <>
              "or set SECRET_KEY_BASE"
    end
  end

  defp generate_secret_key_base!(filepath) do
    key = Base.encode64(:crypto.strong_rand_bytes(64), padding: false)

    case create_private_file(filepath, key) do
      :ok ->
        key

      {:error, reason} ->
        raise "Can't store a new secret key base in #{filepath}: #{:file.format_error(reason)}. Make sure " <>
                "the user Pinchflat runs as can write to #{Path.dirname(filepath)}, or set SECRET_KEY_BASE"
    end
  end

  # A new file can't be given its permissions when it's created, and whoever opens it before they're
  # restricted can keep reading it. So it's written in a new directory only the current user can get
  # into, then moved into place (replacing any file there), so nobody else can ever open it
  defp create_private_file(filepath, content) do
    staging_dir = "#{filepath}-#{Base.url_encode64(:crypto.strong_rand_bytes(6))}.tmp"
    staging_filepath = Path.join(staging_dir, Path.basename(filepath))

    with :ok <- File.mkdir_p(Path.dirname(filepath)),
         :ok <- File.mkdir(staging_dir) do
      try do
        with :ok <- File.chmod(staging_dir, 0o700),
             :ok <- File.write(staging_filepath, content, [:exclusive]),
             :ok <- File.chmod(staging_filepath, 0o600) do
          File.rename(staging_filepath, filepath)
        end
      after
        File.rm_rf(staging_dir)
      end
    end
  end
end
