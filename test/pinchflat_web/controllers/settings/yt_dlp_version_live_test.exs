defmodule PinchflatWeb.Settings.YtDlpVersionLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Settings
  alias Pinchflat.Settings.YtDlpVersionLive

  @pip_error "ERROR: You installed yt-dlp with pip or using the wheel from PyPi; Use that to update"

  setup do
    Settings.set(yt_dlp_version: "2025.09.05")

    :ok
  end

  describe "checking for updates" do
    test "shows that an update is available if the latest release is newer", %{conn: conn} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> latest_release_response("2025.09.26") end)

      {:ok, view, html} = live_isolated(conn, YtDlpVersionLive)

      assert html =~ "Installed version"
      assert html =~ "2025.09.05"
      assert html =~ "Checking…"

      html = render_async(view)

      assert html =~ "Update available: 2025.09.26"
      refute html =~ "Up to date"
    end

    test "shows up to date if the installed version is the latest release", %{conn: conn} do
      Settings.set(yt_dlp_version: "2025.09.26")
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> latest_release_response("2025.09.26") end)

      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive)
      html = render_async(view)

      assert html =~ "Up to date"
      refute html =~ "Update available"
    end

    test "shows up to date if the installed version is newer than the latest release", %{conn: conn} do
      Settings.set(yt_dlp_version: "2025.10.01")
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> latest_release_response("2025.09.26") end)

      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive)
      html = render_async(view)

      assert html =~ "Up to date"
      refute html =~ "Update available"
    end

    test "shows an error if the latest release can't be fetched", %{conn: conn} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:error, "HTTP request failed with status code 403: Forbidden"}
      end)

      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive)
      html = render_async(view)

      assert has_element?(view, "p", "Couldn't check for updates")
      refute html =~ "Update available"
      refute html =~ "Up to date"
    end
  end

  describe "pressing the update button" do
    setup do
      stub(HTTPClientMock, :get, fn _url, _headers, _opts -> latest_release_response("2025.09.26") end)

      :ok
    end

    test "disables the button and shows a spinner while updating", %{conn: conn} do
      expect(YtDlpRunnerMock, :update, fn -> {:ok, "Updated yt-dlp"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.09.26"} end)

      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive)
      render_async(view)

      html = view |> element("button", "Update now") |> render_click()

      assert html =~ "Updating…"
      assert html =~ "animate-spin"
      assert [_button] = html |> Floki.parse_fragment!() |> Floki.find("button[disabled]")

      render_async(view)
    end

    test "shows the new version once the update succeeds", %{conn: conn} do
      expect(YtDlpRunnerMock, :update, fn -> {:ok, "Updated yt-dlp"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.09.26"} end)

      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive)
      assert render_async(view) =~ "Update available: 2025.09.26"

      view |> element("button", "Update now") |> render_click()
      html = render_async(view)

      assert html =~ "Update complete. Installed version: 2025.09.26"
      assert html =~ "Up to date"
      refute html =~ "Update available"
      refute html =~ "animate-spin"
      assert [] = html |> Floki.parse_fragment!() |> Floki.find("button[disabled]")
    end

    test "shows the error output if the update fails", %{conn: conn} do
      expect(YtDlpRunnerMock, :update, fn -> {:error, @pip_error} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.09.05"} end)

      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive)
      render_async(view)

      view |> element("button", "Update now") |> render_click()
      html = render_async(view)

      assert html =~ "Update failed"
      assert html =~ @pip_error
      assert html =~ "Update available: 2025.09.26"
      assert [] = html |> Floki.parse_fragment!() |> Floki.find("button[disabled]")
    end

    test "says the update ran if the installed version can't be read", %{conn: conn} do
      expect(YtDlpRunnerMock, :update, fn -> {:ok, "Updated yt-dlp"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:error, "version error"} end)

      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive)
      render_async(view)

      view |> element("button", "Update now") |> render_click()
      html = render_async(view)

      assert has_element?(view, "p", "Update ran, but couldn't read the installed version")
      assert html =~ "version error"
      refute html =~ "Update failed"
    end

    test "ignores presses while an update is already running", %{conn: conn} do
      test_pid = self()

      expect(YtDlpRunnerMock, :update, fn ->
        send(test_pid, {:update_started, self()})

        receive do
          :finish_update -> {:ok, "Updated yt-dlp"}
        end
      end)

      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.09.26"} end)

      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive)
      render_async(view)

      render_click(view, "update_yt_dlp", %{})
      assert_receive {:update_started, update_pid}
      # Simulates a double click that arrives before the button is disabled
      render_click(view, "update_yt_dlp", %{})
      send(update_pid, :finish_update)

      assert render_async(view) =~ "Update complete. Installed version: 2025.09.26"
    end

    test "shows the error if the update crashes", %{conn: conn} do
      expect(YtDlpRunnerMock, :update, fn -> raise "yt-dlp exploded" end)

      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive)
      render_async(view)

      view |> element("button", "Update now") |> render_click()
      html = render_async(view)

      assert html =~ "Update failed"
      assert html =~ "yt-dlp exploded"
    end
  end

  defp latest_release_response(tag_name) do
    {:ok, Phoenix.json_library().encode!(%{tag_name: tag_name, name: "yt-dlp #{tag_name}"})}
  end
end
