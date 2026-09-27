defmodule Pinchflat.YtDlp.Updater do
  @moduledoc """
  Methods for updating yt-dlp and checking for newer releases
  """

  alias Pinchflat.Settings

  @latest_release_url "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"

  @doc """
  Updates yt-dlp and saves the installed version to the settings.

  The version is saved even if the update fails so the settings always
  reflect what is installed. If the update fails, its output is returned.
  If the update ran but the installed version couldn't be read, the output
  of the version command is returned as `{:version, output}`.

  Returns {:ok, binary()} | {:error, binary()} | {:error, {:version, binary()}}
  """
  def update_and_record_version do
    update_result = yt_dlp_runner().update()
    version_result = record_version()

    case update_result do
      {:ok, _output} -> version_result
      {:error, output} -> {:error, output}
    end
  end

  @doc """
  Fetches the version (tag name) of the latest stable yt-dlp release from GitHub.

  Returns {:ok, binary()} | {:error, binary()}
  """
  def latest_version do
    # GitHub's API rejects requests that don't have a User-Agent
    headers = ["user-agent": "pinchflat", accept: "application/vnd.github+json"]
    opts = [http_options: [timeout: 10_000, connect_timeout: 5_000]]

    with {:ok, body} <- http_client().get(@latest_release_url, headers, opts) do
      parse_tag_name(body)
    end
  end

  defp record_version do
    case yt_dlp_runner().version() do
      {:ok, version} ->
        Settings.set(yt_dlp_version: version)

        {:ok, version}

      {:error, output} ->
        {:error, {:version, output}}
    end
  end

  defp parse_tag_name(body) do
    case Phoenix.json_library().decode(body) do
      {:ok, %{"tag_name" => tag_name}} when is_binary(tag_name) -> {:ok, tag_name}
      _ -> {:error, "Unexpected response when fetching the latest yt-dlp release"}
    end
  end

  defp yt_dlp_runner do
    Application.get_env(:pinchflat, :yt_dlp_runner)
  end

  defp http_client do
    Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
  end
end
