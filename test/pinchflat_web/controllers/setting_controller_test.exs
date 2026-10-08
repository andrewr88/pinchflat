defmodule PinchflatWeb.SettingControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Utils.FilesystemUtils

  describe "show settings" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/settings")

      assert html_response(conn, 200) =~ "Settings"
    end
  end

  describe "update settings" do
    test "saves and redirects when data is valid", %{conn: conn} do
      update_attrs = %{apprise_server: "test://server"}

      conn = put(conn, ~p"/settings", setting: update_attrs)
      assert redirected_to(conn) == ~p"/settings"

      conn = get(conn, ~p"/settings")
      assert html_response(conn, 200) =~ update_attrs[:apprise_server]
    end
  end

  describe "app_info" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/app_info")

      assert html_response(conn, 200) =~ "App Info"
    end
  end

  describe "download_logs" do
    test "downloads logs", %{conn: conn} do
      log_path = Path.join([System.tmp_dir!(), "pinchflat", "data", "pinchflat.log"])
      FilesystemUtils.write_p(log_path, "test log data")
      Application.put_env(:pinchflat, :log_path, log_path)

      conn = get(conn, ~p"/download_logs")

      assert response(conn, 200) =~ "test log data"

      Application.put_env(:pinchflat, :log_path, nil)
    end

    test "redirects when log file is not found", %{conn: conn} do
      conn = get(conn, ~p"/download_logs")

      assert redirected_to(conn) == ~p"/app_info"
      assert conn.assigns[:flash]["error"] == "Log file couldn't be found"
    end
  end

  describe "save_cookies" do
    setup :setup_cookie_file

    test "saves the cookies and redirects", %{conn: conn, cookie_file: cookie_file} do
      File.rm(cookie_file)

      conn = post(conn, ~p"/settings/save_cookies", cookie_content: "cookie data")

      assert redirected_to(conn) == ~p"/settings"
      assert conn.assigns[:flash]["info"] == "Cookies saved successfully."
      assert File.read!(cookie_file) == "cookie data"
    end

    test "makes the cookie file readable only by its owner", %{conn: conn, cookie_file: cookie_file} do
      FilesystemUtils.write_p!(cookie_file, "")
      File.chmod!(cookie_file, 0o644)

      post(conn, ~p"/settings/save_cookies", cookie_content: "cookie data")

      assert File.stat!(cookie_file).mode == 0o100600
    end
  end

  describe "validate_cookies" do
    setup :setup_cookie_file

    # No yt-dlp mock is set up, so this also checks yt-dlp isn't run
    test "shows an error without running yt-dlp when there's no cookie file", %{conn: conn, cookie_file: cookie_file} do
      File.rm(cookie_file)

      conn = post(conn, ~p"/settings/validate_cookies")

      assert redirected_to(conn) == ~p"/settings"
      assert conn.assigns[:flash]["error"] == "No cookie file found. Please save your cookies first."
    end

    test "shows a success message when yt-dlp can use the cookies", %{conn: conn, cookie_file: cookie_file} do
      FilesystemUtils.write_p!(cookie_file, "cookie data")

      expect(YtDlpRunnerMock, :run, fn _url, :validate_cookies, _opts, _ot, addl_opts ->
        assert addl_opts[:use_cookies]

        {:ok, ""}
      end)

      conn = post(conn, ~p"/settings/validate_cookies")

      assert redirected_to(conn) == ~p"/settings"

      assert conn.assigns[:flash]["info"] ==
               "Cookies validated successfully! Your cookies can access private playlists."
    end

    test "shows an error when yt-dlp can't access the private playlist", %{conn: conn, cookie_file: cookie_file} do
      FilesystemUtils.write_p!(cookie_file, "cookie data")

      expect(YtDlpRunnerMock, :run, fn _url, :validate_cookies, _opts, _ot, _addl_opts ->
        {:error, "ERROR: [youtube:tab] LL: This is a private playlist. Sign in if you've been granted access", 1}
      end)

      conn = post(conn, ~p"/settings/validate_cookies")

      assert redirected_to(conn) == ~p"/settings"

      assert conn.assigns[:flash]["error"] ==
               "Cookies validation failed: Cannot access private playlist. " <>
                 "Please check that your cookies are valid and not expired."
    end
  end

  defp setup_cookie_file(_context) do
    cookie_file = Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt")
    # Don't leave cookies around for other tests that run yt-dlp with `use_cookies`
    on_exit(fn -> File.rm(cookie_file) end)

    %{cookie_file: cookie_file}
  end
end
