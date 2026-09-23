defmodule PinchflatWeb.Pages.HistoryTableLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Pages.HistoryTableLive

  setup do
    source = source_fixture()

    {:ok, source: source}
  end

  describe "initial rendering" do
    test "shows downloaded media when downloaded", %{conn: conn, source: source} do
      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, HistoryTableLive, session: create_session("downloaded"))

      assert html =~ downloaded_media_item.title
      refute html =~ pending_media_item.title
    end

    test "shows pending media when pending", %{conn: conn, source: source} do
      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, HistoryTableLive, session: create_session("pending"))

      assert html =~ pending_media_item.title
      refute html =~ downloaded_media_item.title
    end
  end

  describe "job:state events" do
    test "reloads the records on the scheduled reload", %{conn: conn, source: source} do
      {:ok, view, html} = live_isolated(conn, HistoryTableLive, session: create_session("downloaded"))
      assert html =~ "Nothing Here!"

      media_item = media_item_fixture(source_id: source.id)
      for _ <- 1..3, do: PinchflatWeb.Endpoint.broadcast("job:state", "change", nil)

      assert reload_pending?(view)
      refute render(view) =~ media_item.title

      send(view.pid, :reload)

      refute reload_pending?(view)
      assert render(view) =~ media_item.title
    end

    test "stays on the current page when reloading", %{conn: conn, source: source} do
      [oldest, second_oldest | _] = Enum.map(1..6, fn _ -> media_item_fixture(source_id: source.id) end)
      {:ok, view, _html} = live_isolated(conn, HistoryTableLive, session: create_session("downloaded"))

      html = view |> element("span.pagination-next") |> render_click()
      assert html =~ oldest.title
      refute html =~ second_oldest.title

      newest = media_item_fixture(source_id: source.id)
      PinchflatWeb.Endpoint.broadcast("job:state", "change", nil)
      send(view.pid, :reload)

      html = render(view)
      assert html =~ oldest.title
      assert html =~ second_oldest.title
      refute html =~ newest.title
    end
  end

  defp create_session(media_state) do
    %{"media_state" => media_state}
  end

  defp reload_pending?(view) do
    :sys.get_state(view.pid).socket.assigns.reload_pending
  end
end
