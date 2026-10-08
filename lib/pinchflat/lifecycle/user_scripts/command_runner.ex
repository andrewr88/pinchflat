defmodule Pinchflat.Lifecycle.UserScripts.CommandRunner do
  @moduledoc """
  Runs custom user commands commands using the `System.cmd/3` function
  """

  require Logger

  alias Pinchflat.Utils.CliUtils
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Lifecycle.UserScripts.UserScriptCommandRunner

  @behaviour UserScriptCommandRunner

  @event_types [
    :app_init,
    :media_pre_download,
    :media_downloaded,
    :media_deleted
  ]

  @doc """
  Runs the user script command for the given event type. Passes the event
  and the encoded data to the user script command.

  This function will succeed in almost all cases, even if the user script command
  failed - this is because I don't want bad scripts to stop the whole process.
  If something fails, it'll be logged and returned BUT the tuple will always
  start with {:ok, ...}.

  Exit codes from 1 to 125 come from the script itself (for `:media_pre_download`,
  they veto the download). Higher ones mean the script couldn't run or finish:
    - 126: the lifecycle file isn't executable
    - 127: the lifecycle file or its interpreter (eg: from a bad shebang) wasn't found
    - 128 and up: it was killed by a signal (128 + the signal's number, eg: 137 for SIGKILL)

  The only things that can cause a true failure are passing in an invalid event
  type or if the passed data cannot be encoded into JSON - both indicative of
  failures in the development process.

  Returns {:ok, :no_executable} | {:ok, output, exit_code}
  """
  @impl UserScriptCommandRunner
  def run(event_type, encodable_data) when event_type in @event_types do
    case backend_executable() do
      {:ok, :no_executable} ->
        {:ok, :no_executable}

      {:ok, executable_path} ->
        {:ok, encoded_data} = Phoenix.json_library().encode(encodable_data)

        {output, exit_code} =
          CliUtils.wrap_cmd(
            executable_path,
            [to_string(event_type), encoded_data],
            [],
            logging_arg_override: "[suppressed]"
          )

        {:ok, output, exit_code}
    end
  end

  def run(event_type, _encodable_data) do
    raise ArgumentError, "Invalid event type: #{inspect(event_type)}"
  end

  @doc """
  Returns the path of the user script command (the lifecycle file), whether it exists or not.

  Returns binary()
  """
  def lifecycle_filepath do
    base_dir = Application.get_env(:pinchflat, :extras_directory)

    Path.join([base_dir, "user-scripts", "lifecycle"])
  end

  defp backend_executable do
    filepath = lifecycle_filepath()

    if FilesystemUtils.exists_and_nonempty?(filepath) do
      {:ok, filepath}
    else
      Logger.info("User scripts lifecyle file either not present or is empty. Skipping.")

      {:ok, :no_executable}
    end
  end
end
