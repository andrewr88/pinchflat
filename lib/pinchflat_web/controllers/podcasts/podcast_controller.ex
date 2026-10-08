defmodule PinchflatWeb.Podcasts.PodcastController do
  use PinchflatWeb, :controller

  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Podcasts.PodcastHelpers
  alias PinchflatWeb.Podcasts.RssFeedBuilder
  alias PinchflatWeb.Podcasts.OpmlFeedBuilder
  alias PinchflatWeb.Router.Helpers, as: Routes

  def opml_feed(conn, _params) do
    xml = OpmlFeedBuilder.build(url_base(conn), PodcastHelpers.opml_sources())

    conn
    |> put_resp_content_type("application/opml+xml")
    |> put_resp_header("content-disposition", "inline")
    |> send_resp(200, xml)
  end

  def rss_feed(conn, %{"uuid" => uuid}) do
    source = Repo.get_by!(Source, uuid: uuid)
    xml = RssFeedBuilder.build(source, url_base: url_base(conn))

    conn
    |> put_resp_content_type("application/rss+xml")
    |> put_resp_header("content-disposition", "inline")
    |> send_resp(200, xml)
  end

  def feed_image(conn, %{"uuid" => uuid}) do
    source = Repo.get_by!(Source, uuid: uuid)

    # If the source doesn't have any usable images, the cover image falls back to the first media
    # item's thumbnail. Using the feed's first (ie: newest) item serves the image the feed advertises
    media_items = PodcastHelpers.persisted_media_items_for(source, limit: 1)

    case PodcastHelpers.select_cover_image(source, media_items) do
      {:error, _} ->
        send_resp(conn, 404, "Image not found")

      {:ok, filepath} ->
        conn
        |> put_resp_content_type(MIME.from_path(filepath))
        |> send_file(200, filepath)
    end
  end

  def episode_image(conn, %{"uuid" => uuid}) do
    media_item = Repo.get_by!(MediaItem, uuid: uuid)

    case PodcastHelpers.select_episode_image(media_item) do
      {:error, _} ->
        send_resp(conn, 404, "Image not found")

      {:ok, filepath} ->
        conn
        |> put_resp_content_type(MIME.from_path(filepath))
        |> send_file(200, filepath)
    end
  end

  # The scheme, host, and port of the request (see `override_base_url` in endpoint.ex) without
  # a path. The feeds' routes already include the endpoint's path (eg: from BASE_ROUTE_PATH)
  defp url_base(conn), do: Routes.url(conn)
end
