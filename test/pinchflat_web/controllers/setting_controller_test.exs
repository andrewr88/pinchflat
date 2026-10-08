defmodule PinchflatWeb.SettingControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Settings
  alias Pinchflat.Settings.Setting
  alias Pinchflat.Utils.FilesystemUtils

  describe "show settings" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/settings")

      assert html_response(conn, 200) =~ "Settings"
    end

    # ConnTest skips CSRF protection, so without a token these forms only fail in a browser
    test "gives each cookie form a CSRF token", %{conn: conn} do
      document = conn |> get(~p"/settings") |> html_response(200) |> Floki.parse_document!()

      for action <- [~p"/settings/save_cookies", ~p"/settings/validate_cookies"] do
        assert [_token] =
                 document
                 |> Floki.find(~s(form[action="#{action}"] input[type="hidden"][name="_csrf_token"]))
                 |> Floki.attribute("value"),
               "expected the #{action} form to have a CSRF token"
      end
    end
  end

  describe "cookie forms with CSRF protection" do
    setup :setup_cookie_file

    test "save the cookies using the form's CSRF token", %{conn: conn, cookie_file: cookie_file} do
      conn = get(conn, ~p"/settings")
      token = cookie_form_csrf_token(html_response(conn, 200), ~p"/settings/save_cookies")

      conn = post(enforce_csrf(conn), ~p"/settings/save_cookies", _csrf_token: token, cookie_content: "cookie data")

      assert redirected_to(conn) == ~p"/settings"
      assert File.read!(cookie_file) == "cookie data"
    end

    # No yt-dlp mock is set up, so this also checks yt-dlp isn't run
    test "validate the cookies using the form's CSRF token", %{conn: conn, cookie_file: cookie_file} do
      File.rm(cookie_file)
      conn = get(conn, ~p"/settings")
      token = cookie_form_csrf_token(html_response(conn, 200), ~p"/settings/validate_cookies")

      conn = post(enforce_csrf(conn), ~p"/settings/validate_cookies", _csrf_token: token)

      assert redirected_to(conn) == ~p"/settings"
      assert conn.assigns[:flash]["error"] == "No cookie file found. Please save your cookies first."
    end

    # Shows that the tests above actually go through CSRF protection
    test "are rejected without a CSRF token", %{conn: conn, cookie_file: cookie_file} do
      File.rm(cookie_file)
      conn = get(conn, ~p"/settings")

      assert_error_sent 403, fn ->
        post(enforce_csrf(conn), ~p"/settings/save_cookies", cookie_content: "cookie data")
      end

      refute File.exists?(cookie_file)
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

    test "saves each field on the form", %{conn: conn} do
      form_params = %{
        "apprise_server" => "test://server",
        "youtube_api_key" => "ABC123,DEF456",
        "extractor_sleep_interval_seconds" => "5",
        "download_throughput_limit" => "4.2M",
        "restrict_filenames" => "true",
        "video_codec_preference" => "vp9",
        "audio_codec_preference" => "opus"
      }

      # Fails when a field is added to the form, as a reminder to make sure it can be saved
      html = conn |> get(~p"/settings") |> html_response(200)
      assert form_field_names(html, "setting") == Enum.sort(Map.keys(form_params))

      put(conn, ~p"/settings", setting: form_params)

      assert %Setting{
               apprise_server: "test://server",
               youtube_api_key: "ABC123,DEF456",
               extractor_sleep_interval_seconds: 5,
               download_throughput_limit: "4.2M",
               restrict_filenames: true,
               video_codec_preference: "vp9",
               audio_codec_preference: "opus"
             } = Settings.record()
    end

    # The app sets these itself, eg: the installed versions are shown on the app info page
    test "doesn't set fields that aren't on the form", %{conn: conn} do
      setting = Settings.record()

      params = %{
        "apprise_server" => "test://server",
        "onboarding" => to_string(!setting.onboarding),
        "pro_enabled" => to_string(!setting.pro_enabled),
        "yt_dlp_version" => "1.2.3",
        "apprise_version" => "4.5.6"
      }

      conn = put(conn, ~p"/settings", setting: params)

      assert redirected_to(conn) == ~p"/settings"
      updated_setting = Settings.record()
      assert updated_setting.apprise_server == "test://server"

      assert Map.take(updated_setting, [:onboarding, :pro_enabled, :yt_dlp_version, :apprise_version]) ==
               Map.take(setting, [:onboarding, :pro_enabled, :yt_dlp_version, :apprise_version])
    end
  end

  describe "app_info" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/app_info")

      assert html_response(conn, 200) =~ "App Info"
    end
  end

  describe "download_logs" do
    setup do
      original_log_path = Application.get_env(:pinchflat, :log_path)
      on_exit(fn -> Application.put_env(:pinchflat, :log_path, original_log_path) end)

      :ok
    end

    test "downloads logs", %{conn: conn} do
      log_path = Path.join([System.tmp_dir!(), "pinchflat", "data", "pinchflat.log"])
      FilesystemUtils.write_p!(log_path, "test log data")
      Application.put_env(:pinchflat, :log_path, log_path)

      conn = get(conn, ~p"/download_logs")

      assert response(conn, 200) =~ "test log data"
      assert [content_disposition] = get_resp_header(conn, "content-disposition")
      assert content_disposition =~ ~r/\Aattachment; filename="pinchflat-logs-\d{4}-\d{2}-\d{2}\.txt"\z/
    end

    test "redirects when log file is not found", %{conn: conn} do
      Application.put_env(:pinchflat, :log_path, nil)

      conn = get(conn, ~p"/download_logs")

      assert redirected_to(conn) == ~p"/app_info"
      assert conn.assigns[:flash]["error"] == "Log file couldn't be found"
    end

    test "redirects when the log path is set but there's no file there", %{conn: conn} do
      Application.put_env(:pinchflat, :log_path, Path.join([System.tmp_dir!(), "pinchflat", "data", "missing.log"]))

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

    test "shows an error when the cookies can't be written", %{conn: conn, cookie_file: cookie_file} do
      File.rm(cookie_file)
      # A directory in the cookie file's place can't be written to
      File.mkdir_p!(cookie_file)
      on_exit(fn -> File.rm_rf(cookie_file) end)

      conn = post(conn, ~p"/settings/save_cookies", cookie_content: "cookie data")

      assert redirected_to(conn) == ~p"/settings"
      assert conn.assigns[:flash]["error"] == "Failed to save cookies: :eisdir"
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

    test "shows an error when yt-dlp can't access private or age-restricted videos", %{
      conn: conn,
      cookie_file: cookie_file
    } do
      FilesystemUtils.write_p!(cookie_file, "cookie data")

      for output <- ["ERROR: [youtube] abc123: Private video", "ERROR: [youtube] abc123: Sign in to confirm your age"] do
        expect(YtDlpRunnerMock, :run, fn _url, :validate_cookies, _opts, _ot, _addl_opts -> {:error, output, 1} end)

        conn = post(conn, ~p"/settings/validate_cookies")

        assert conn.assigns[:flash]["error"] ==
                 "Cookies validation failed: Cannot access private playlist. " <>
                   "Please check that your cookies are valid and not expired."
      end
    end

    test "shows an error when yt-dlp has a problem with the cookie file", %{conn: conn, cookie_file: cookie_file} do
      FilesystemUtils.write_p!(cookie_file, "cookie data")

      expect(YtDlpRunnerMock, :run, fn _url, :validate_cookies, _opts, _ot, _addl_opts ->
        {:error, "ERROR: invalid Netscape format cookies file", 1}
      end)

      conn = post(conn, ~p"/settings/validate_cookies")

      assert conn.assigns[:flash]["error"] ==
               "Cookies validation failed: Cookie file error. Please check your cookie file format."
    end

    test "shows the start of yt-dlp's output for other errors", %{conn: conn, cookie_file: cookie_file} do
      FilesystemUtils.write_p!(cookie_file, "cookie data")
      output = "ERROR: something went wrong " <> String.duplicate("a", 300)

      expect(YtDlpRunnerMock, :run, fn _url, :validate_cookies, _opts, _ot, _addl_opts -> {:error, output, 1} end)

      conn = post(conn, ~p"/settings/validate_cookies")

      assert conn.assigns[:flash]["error"] == "Cookies validation failed: " <> String.slice(output, 0, 200)
    end
  end

  defp setup_cookie_file(_context) do
    cookie_file = Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt")
    # Don't leave cookies around for other tests that run yt-dlp with `use_cookies`
    on_exit(fn -> File.rm(cookie_file) end)

    %{cookie_file: cookie_file}
  end

  # The next request from the browser that rendered `conn`, with CSRF protection (which ConnTest skips)
  defp enforce_csrf(conn) do
    conn
    |> recycle()
    |> put_private(:plug_skip_csrf_protection, false)
  end

  defp cookie_form_csrf_token(html, action) do
    [token] =
      html
      |> Floki.parse_document!()
      |> Floki.find(~s(form[action="#{action}"] input[name="_csrf_token"]))
      |> Floki.attribute("value")

    token
  end

  # The fields of a form's inputs, eg: "apprise_server" for `name="setting[apprise_server]"`
  defp form_field_names(html, param_name) do
    ~r/name="#{param_name}\[(\w+)\]"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end
end
