defmodule PinchflatWeb.Settings.SettingController do
  use PinchflatWeb, :controller

  alias Pinchflat.Settings

  def show(conn, _params) do
    setting = Settings.record()
    changeset = Settings.change_setting(setting)

    render(conn, "show.html", changeset: changeset)
  end

  def update(conn, %{"setting" => setting_params}) do
    setting = Settings.record()

    case Settings.update_setting(setting, setting_params) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Settings updated successfully.")
        |> redirect(to: ~p"/settings")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "show.html", changeset: changeset)
    end
  end

  def app_info(conn, _params) do
    render(conn, "app_info.html")
  end

  def download_logs(conn, _params) do
    log_path = Application.get_env(:pinchflat, :log_path)

    if log_path && File.exists?(log_path) do
      send_download(conn, {:file, log_path}, filename: "pinchflat-logs-#{Date.utc_today()}.txt")
    else
      conn
      |> put_flash(:error, "Log file couldn't be found")
      |> redirect(to: ~p"/app_info")
    end
  end

  def save_cookies(conn, %{"cookie_content" => cookie_content}) do
    base_dir = Application.get_env(:pinchflat, :extras_directory)
    cookie_file = Path.join(base_dir, "cookies.txt")

    case Pinchflat.Utils.FilesystemUtils.write_p(cookie_file, cookie_content) do
      :ok ->
        conn
        |> put_flash(:info, "Cookies saved successfully.")
        |> redirect(to: ~p"/settings")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Failed to save cookies: #{inspect(reason)}")
        |> redirect(to: ~p"/settings")
    end
  end

  def validate_cookies(conn, _params) do
    base_dir = Application.get_env(:pinchflat, :extras_directory)
    cookie_file = Path.join(base_dir, "cookies.txt")

    # Check if cookie file exists and is non-empty
    unless Pinchflat.Utils.FilesystemUtils.exists_and_nonempty?(cookie_file) do
      conn
      |> put_flash(:error, "No cookie file found. Please save your cookies first.")
      |> redirect(to: ~p"/settings")
    else

    # Validate cookies by trying to access the private Liked Videos playlist
    # This playlist requires authentication and is a good test for cookie validity
    liked_videos_url = "https://www.youtube.com/playlist?list=LL"

    # Use a minimal command to just check if we can access the playlist
    command_opts = [:simulate, :skip_download, playlist_end: 1]
    runner_opts = [use_cookies: true, skip_sleep_interval: true]

    case Pinchflat.YtDlp.CommandRunner.run(liked_videos_url, :validate_cookies, command_opts, "%(.{id,title})j", runner_opts) do
      {:ok, _output} ->
        conn
        |> put_flash(:info, "Cookies validated successfully! Your cookies can access private playlists.")
        |> redirect(to: ~p"/settings")

      {:error, output, _status} ->
        # Check if the error is specifically about authentication/access
        error_message =
          cond do
            String.contains?(output, "Private video") or
            String.contains?(output, "Sign in to confirm your age") or
            String.contains?(output, "This is a private playlist") ->
              "Cookies validation failed: Cannot access private playlist. Please check that your cookies are valid and not expired."

            String.contains?(output, "cookies") ->
              "Cookies validation failed: Cookie file error. Please check your cookie file format."

            true ->
              "Cookies validation failed: #{String.slice(output, 0, 200)}"
          end

        conn
        |> put_flash(:error, error_message)
        |> redirect(to: ~p"/settings")
    end
    end
  end
end
