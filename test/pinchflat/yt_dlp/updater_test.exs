defmodule Pinchflat.YtDlp.UpdaterTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.Updater

  describe "update_and_record_version/0" do
    setup do
      Settings.set(yt_dlp_version: "2025.01.01")

      :ok
    end

    test "updates yt-dlp and records the new version" do
      expect(YtDlpRunnerMock, :update, fn -> {:ok, "Updated yt-dlp"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.09.26"} end)

      assert {:ok, "2025.09.26"} = Updater.update_and_record_version()
      assert Settings.get!(:yt_dlp_version) == "2025.09.26"
    end

    test "returns the update output but still records the version if the update fails" do
      expect(YtDlpRunnerMock, :update, fn -> {:error, "ERROR: Unable to update"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.09.05"} end)

      assert {:error, "ERROR: Unable to update"} = Updater.update_and_record_version()
      assert Settings.get!(:yt_dlp_version) == "2025.09.05"
    end

    test "returns the version output and keeps the old version if getting the version fails" do
      expect(YtDlpRunnerMock, :update, fn -> {:ok, "Updated yt-dlp"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:error, "version error"} end)

      assert {:error, {:version, "version error"}} = Updater.update_and_record_version()
      assert Settings.get!(:yt_dlp_version) == "2025.01.01"
    end
  end

  describe "latest_version/0" do
    test "returns the tag name of the latest yt-dlp release" do
      expect(HTTPClientMock, :get, fn url, headers, opts ->
        assert url == "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
        assert headers == ["user-agent": "pinchflat", accept: "application/vnd.github+json"]
        assert opts == [http_options: [timeout: 10_000, connect_timeout: 5_000]]

        {:ok, ~s({"tag_name": "2025.09.26", "name": "yt-dlp 2025.09.26"})}
      end)

      assert {:ok, "2025.09.26"} = Updater.latest_version()
    end

    test "returns an error if the request fails" do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:error, "HTTP request failed with status code 403: Forbidden"}
      end)

      assert {:error, "HTTP request failed with status code 403: Forbidden"} = Updater.latest_version()
    end

    test "returns an error if the response isn't valid JSON" do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<html>Not JSON</html>"} end)

      assert {:error, _reason} = Updater.latest_version()
    end
  end
end
