defmodule Pinchflat.FastIndexing.YoutubeRssTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.FastIndexing.YoutubeRss

  setup do
    source = source_fixture()

    {:ok, source: source}
  end

  describe "enabled?/0" do
    test "returns true" do
      assert YoutubeRss.enabled?()
    end
  end

  describe "get_recent_media_ids/1" do
    test "calls the expected URL for channel sources" do
      source = source_fixture(collection_type: :channel, collection_id: "channel_id")

      expect(HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url =~ "https://www.youtube.com/feeds/videos.xml?channel_id=#{source.collection_id}"

        {:ok, ""}
      end)

      assert {:ok, _} = YoutubeRss.get_recent_media_ids(source)
    end

    test "calls the expected URL for playlist sources" do
      source = source_fixture(collection_type: :playlist, collection_id: "playlist_id")

      expect(HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url =~ "https://www.youtube.com/feeds/videos.xml?playlist_id=#{source.collection_id}"

        {:ok, ""}
      end)

      assert {:ok, _} = YoutubeRss.get_recent_media_ids(source)
    end

    test "returns an error with the reason if the HTTP request fails", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:error, "HTTP request failed with status code 500: Internal Server Error"}
      end)

      assert {:error, "Failed to fetch RSS feed: HTTP request failed with status code 500: Internal Server Error"} =
               YoutubeRss.get_recent_media_ids(source)
    end

    test "returns an error if the HTTP request fails with a non-string reason", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:error, {:failed_connect, []}} end)

      assert {:error, "Failed to fetch RSS feed: {:failed_connect, []}"} = YoutubeRss.get_recent_media_ids(source)
    end

    test "returns the media IDs from the RSS feed", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, "<yt:videoId>test_1</yt:videoId><yt:videoId>test_2</yt:videoId>"}
      end)

      assert {:ok, ["test_1", "test_2"]} = YoutubeRss.get_recent_media_ids(source)
    end

    test "strips whitespace from media IDs", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, "<yt:videoId> test_1 </yt:videoId><yt:videoId> test_2 </yt:videoId>"}
      end)

      assert {:ok, ["test_1", "test_2"]} = YoutubeRss.get_recent_media_ids(source)
    end

    test "removes empty media IDs", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, "<yt:videoId>test_1</yt:videoId><yt:videoId></yt:videoId>"}
      end)

      assert {:ok, ["test_1"]} = YoutubeRss.get_recent_media_ids(source)
    end

    test "removes duplicate media IDs", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, "<yt:videoId>test_1</yt:videoId><yt:videoId>test_1</yt:videoId>"}
      end)

      assert {:ok, ["test_1"]} = YoutubeRss.get_recent_media_ids(source)
    end
  end
end
