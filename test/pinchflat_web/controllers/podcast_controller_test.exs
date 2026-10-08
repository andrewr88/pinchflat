defmodule PinchflatWeb.PodcastControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  describe "opml_feed" do
    test "renders the XML document", %{conn: conn} do
      source = source_fixture()
      route_token = Settings.get!(:route_token)

      conn = get(conn, ~p"/sources/opml.xml?#{[route_token: route_token]}")

      assert conn.status == 200
      assert {"content-type", "application/opml+xml; charset=utf-8"} in conn.resp_headers
      assert {"content-disposition", "inline"} in conn.resp_headers
      assert conn.resp_body =~ ~s"http://www.example.com/sources/#{source.uuid}/feed.xml"
      assert conn.resp_body =~ "text=\"#{source.custom_name}\""
    end

    test "uses the x-forwarded-proto header (case-insensitively) for the URL scheme", %{conn: conn} do
      source = source_fixture()
      route_token = Settings.get!(:route_token)

      conn =
        conn
        |> put_req_header("x-forwarded-proto", "HTTPS")
        |> get(~p"/sources/opml.xml?#{[route_token: route_token]}")

      assert conn.resp_body =~ ~s"https://www.example.com/sources/#{source.uuid}/feed.xml"
    end

    test "ignores an x-forwarded-proto header that isn't http or https", %{conn: conn} do
      source = source_fixture()
      route_token = Settings.get!(:route_token)

      conn =
        conn
        |> put_req_header("x-forwarded-proto", "https://evil.example.com/?")
        |> get(~p"/sources/opml.xml?#{[route_token: route_token]}")

      assert conn.resp_body =~ ~s"http://www.example.com/sources/#{source.uuid}/feed.xml"
      refute conn.resp_body =~ "evil.example.com"
    end

    test "returns 401 if the route token is incorrect", %{conn: conn} do
      conn = get(conn, ~p"/sources/opml.xml?route_token=incorrect")

      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
    end

    test "returns 401 if the route token is missing", %{conn: conn} do
      conn = get(conn, ~p"/sources/opml.xml")

      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
    end
  end

  describe "rss_feed" do
    test "renders the XML document", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source.uuid}/feed" <> ".xml")

      assert conn.status == 200
      assert {"content-type", "application/rss+xml; charset=utf-8"} in conn.resp_headers
      assert {"content-disposition", "inline"} in conn.resp_headers
    end

    test "uses the x-forwarded-proto header (case-insensitively) for the feed's URLs", %{conn: conn} do
      source = source_with_metadata_attachments()
      media_item = media_item_with_attachments(%{source_id: source.id})

      conn =
        conn
        |> put_req_header("x-forwarded-proto", "HTTPS")
        |> get(~p"/sources/#{source.uuid}/feed" <> ".xml")

      assert feed_urls(conn.resp_body) == expected_feed_urls("https://www.example.com", source, media_item)
    end

    test "ignores an x-forwarded-proto header that isn't http or https", %{conn: conn} do
      source = source_with_metadata_attachments()
      media_item = media_item_with_attachments(%{source_id: source.id})

      conn =
        conn
        |> put_req_header("x-forwarded-proto", "https://evil.example.com/?")
        |> get(~p"/sources/#{source.uuid}/feed" <> ".xml")

      assert feed_urls(conn.resp_body) == expected_feed_urls("http://www.example.com", source, media_item)
      refute conn.resp_body =~ "evil.example.com"
    end

    # The host header comes from the client and can contain characters like `&`
    test "escapes the host in the feed's URLs", %{conn: conn} do
      source = source_with_metadata_attachments()
      media_item = media_item_with_attachments(%{source_id: source.id})

      conn = get(%{conn | host: "a&b.com"}, ~p"/sources/#{source.uuid}/feed" <> ".xml")

      assert feed_urls(conn.resp_body) == expected_feed_urls("http://a&b.com", source, media_item)
    end

    test "returns 404 if the source can't be found", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/sources/#{Ecto.UUID.generate()}/feed" <> ".xml")
      end
    end
  end

  describe "feed_image" do
    test "returns a feed image if one can be found", %{conn: conn} do
      source = source_with_metadata_attachments()

      conn = get(conn, ~p"/sources/#{source.uuid}/feed_image" <> ".jpg")

      assert conn.status == 200
      assert {"content-type", "image/jpeg; charset=utf-8"} in conn.resp_headers
      assert conn.resp_body == File.read!(source.metadata.poster_filepath)
    end

    # The feed advertises the newest media item's thumbnail as its image if the source doesn't have one
    test "falls back to the thumbnail of the newest media item in the feed", %{conn: conn} do
      source = source_fixture()
      older = media_item_with_metadata_attachments(%{source_id: source.id, uploaded_at: now_minus(1, :day)})
      newer = media_item_with_metadata_attachments(%{source_id: source.id, uploaded_at: now()})
      File.rm!(older.metadata.thumbnail_filepath)
      File.write!(newer.metadata.thumbnail_filepath, "newer thumbnail")

      feed_conn = get(conn, ~p"/sources/#{source.uuid}/feed" <> ".xml")
      feed_image_url = xpath_string(parse_xml(feed_conn.resp_body), "/rss/channel/itunes:image/@href")

      assert feed_image_url == "http://www.example.com/sources/#{source.uuid}/feed_image.jpg"

      conn = get(conn, feed_image_url)

      assert conn.status == 200
      assert conn.resp_body == "newer thumbnail"
    end

    test "returns 404 if an image cannot be found", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source.uuid}/feed_image" <> ".jpg")

      assert conn.status == 404
      assert conn.resp_body == "Image not found"
    end

    test "returns 404 if the source can't be found", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/sources/#{Ecto.UUID.generate()}/feed_image" <> ".jpg")
      end
    end
  end

  describe "episode_image" do
    test "returns an episode image if one can be found", %{conn: conn} do
      media_item = media_item_with_attachments()

      conn = get(conn, ~p"/media/#{media_item.uuid}/episode_image" <> ".jpg")

      assert conn.status == 200
      assert {"content-type", "image/jpeg; charset=utf-8"} in conn.resp_headers
      assert conn.resp_body == File.read!(media_item.thumbnail_filepath)
    end

    test "returns 404 if an image cannot be found", %{conn: conn} do
      media_item = media_item_fixture()

      conn = get(conn, ~p"/media/#{media_item.uuid}/episode_image" <> ".jpg")

      assert conn.status == 404
      assert conn.resp_body == "Image not found"
    end

    test "returns 404 if the media item can't be found", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/media/#{Ecto.UUID.generate()}/episode_image" <> ".jpg")
      end
    end
  end

  # BASE_ROUTE_PATH sets the endpoint's URL path (see runtime.exs) for running the app behind
  # a reverse proxy, which strips the path from requests before passing them on
  describe "feeds when the app is served under a path" do
    setup do
      # The endpoint's current config, ie: merged with Phoenix's defaults
      endpoint_config =
        for {key, _value} <- Application.get_env(:pinchflat, PinchflatWeb.Endpoint) do
          {key, PinchflatWeb.Endpoint.config(key)}
        end

      put_endpoint_config(put_in(endpoint_config[:url][:path], "/sub"))
      on_exit(fn -> put_endpoint_config(endpoint_config) end)
    end

    test "includes the path in the RSS feed's URLs once", %{conn: conn} do
      source = source_with_metadata_attachments()
      media_item = media_item_with_attachments(%{source_id: source.id})

      conn = get(conn, "/sources/#{source.uuid}/feed.xml")

      assert feed_urls(conn.resp_body) == expected_feed_urls("http://www.example.com/sub", source, media_item)
    end

    test "includes the path in the OPML feed's URLs once", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, "/sources/opml.xml?route_token=#{Settings.get!(:route_token)}")

      assert xpath_string(parse_xml(conn.resp_body), "//outline/@xmlUrl") ==
               "http://www.example.com/sub/sources/#{source.uuid}/feed.xml"
    end
  end

  defp put_endpoint_config(config) do
    PinchflatWeb.Endpoint.config_change([{PinchflatWeb.Endpoint, config}], [])
  end

  # Every URL in an RSS feed with one item that the app builds from the request, in document order:
  # the feed's own, its image's, then its item's media's and image's
  defp feed_urls(xml) do
    doc = parse_xml(xml)

    Enum.map(
      ~w(/rss/channel/atom:link/@href /rss/channel/image/url /rss/channel/itunes:image/@href
         //item/enclosure/@url //item/itunes:image/@href //item/podcast:images/@srcset),
      &xpath_string(doc, &1)
    )
  end

  defp expected_feed_urls(url_base, source, media_item) do
    feed_image_url = "#{url_base}/sources/#{source.uuid}/feed_image.jpg"
    episode_image_url = "#{url_base}/media/#{media_item.uuid}/episode_image.jpg"

    [
      "#{url_base}/sources/#{source.uuid}/feed.xml",
      feed_image_url,
      feed_image_url,
      "#{url_base}/media/#{media_item.uuid}/stream.mp4",
      episode_image_url,
      episode_image_url
    ]
  end

  # xmerl is a strict parser, so this fails the test if the document isn't well-formed
  defp parse_xml(xml) do
    {doc, _rest} = xml |> :binary.bin_to_list() |> :xmerl_scan.string(quiet: true)

    doc
  end

  defp xpath_string(doc, path) do
    {:xmlObj, :string, value} = :xmerl_xpath.string(~c"string(#{path})", doc)

    List.to_string(value)
  end
end
