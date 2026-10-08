defmodule PinchflatWeb.Sources.MediaItemTableLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias PinchflatWeb.Sources.MediaItemTableLive

  setup do
    source = source_fixture()

    {:ok, source: source}
  end

  describe "initial rendering" do
    test "shows message when no records", %{conn: conn, source: source} do
      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))

      assert html =~ "Nothing Here!"
      refute html =~ "Showing"
    end

    test "shows records when present", %{conn: conn, source: source} do
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))

      assert html =~ "Showing"
      assert html =~ "Title"
      assert html =~ media_item.title
    end
  end

  describe "media_state" do
    test "shows pending media when pending", %{conn: conn, source: source} do
      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "pending"))

      assert html =~ pending_media_item.title
      refute html =~ downloaded_media_item.title
    end

    test "shows downloaded media when downloaded", %{conn: conn, source: source} do
      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert html =~ downloaded_media_item.title
      refute html =~ pending_media_item.title
    end

    test "shows records that aren't pending or downloaded when other", %{conn: conn} do
      media_profile = media_profile_fixture(shorts_behaviour: :exclude)
      source = source_fixture(media_profile_id: media_profile.id)

      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      other_media_item = media_item_fixture(source_id: source.id, media_filepath: nil, short_form_content: true)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "other"))

      assert html =~ other_media_item.title
      refute html =~ downloaded_media_item.title
      refute html =~ pending_media_item.title
    end

    test "shows 'Manually Ignored' column when other", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id, prevent_download: true, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "other"))

      assert html =~ "Manually Ignored?"
    end
  end

  describe "page_change" do
    test "moves between pages without going past the first or last", %{conn: conn, source: source} do
      # A page holds 10 records and the newest uploads come first
      [oldest | newest] =
        Enum.map(10..0//-1, fn days_ago ->
          media_item_fixture(source_id: source.id, media_filepath: nil, uploaded_at: now_minus(days_ago, :days))
        end)

      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))

      html = change_page(view, "dec")
      assert {page(view), titles(html)} == {1, Enum.map(Enum.reverse(newest), & &1.title)}

      change_page(view, "inc")
      html = change_page(view, "inc")
      assert {page(view), titles(html)} == {2, [oldest.title]}

      html = change_page(view, "dec")
      assert {page(view), length(titles(html))} == {1, 10}
    end
  end

  describe "search_term" do
    setup %{source: source} do
      matching_media_item = media_item_fixture(source_id: source.id, media_filepath: nil, title: "A unique snowflake")
      # Enough others for a second page
      others = Enum.map(1..10, fn _ -> media_item_fixture(source_id: source.id, media_filepath: nil) end)

      {:ok, matching_media_item: matching_media_item, others: others}
    end

    test "shows only matching records, starting from the first page", %{
      conn: conn,
      source: source,
      matching_media_item: matching_media_item
    } do
      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))
      change_page(view, "inc")
      assert page(view) == 2

      html = search(view, "snowflake")

      assert {page(view), titles(html)} == {1, [matching_media_item.title]}
      assert html =~ ~r/Showing\s*<span[^>]*>1<\/span>\s*of\s*<span[^>]*>1<\/span>/
    end

    test "keeps the search term when the tables are reloaded", %{
      conn: conn,
      source: source,
      matching_media_item: matching_media_item
    } do
      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))
      search(view, "snowflake")

      media_item_fixture(source_id: source.id, media_filepath: nil, title: "Another snowflake")
      render_click(view, "reload_page")

      assert Enum.sort(titles(render(view))) == Enum.sort([matching_media_item.title, "Another snowflake"])
      assert :sys.get_state(view.pid).socket.assigns.search_term == "snowflake"
    end

    test "shows all records again when the search term is cleared", %{conn: conn, source: source} do
      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))
      search(view, "snowflake")

      html = search(view, "")

      assert length(titles(html)) == 10
      assert {page(view), :sys.get_state(view.pid).socket.assigns.total_pages} == {1, 2}
    end

    # The term goes into an SQLite full-text search, which errors on some syntax
    test "doesn't crash on search terms with full-text search syntax", %{conn: conn, source: source} do
      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))
      terms = [" ", "  \t ", ~s("), ~s(""), "OR", "AND", "NOT", "*", "-", "snow*", "-snowflake", "a OR", "(", ":", "^"]

      for term <- terms do
        assert is_binary(search(view, term)), "expected the term #{inspect(term)} to render"
      end

      assert titles(search(view, " snowflake ")) != []
    end
  end

  defp create_session(source, media_state \\ "pending") do
    %{"source_id" => source.id, "media_state" => media_state}
  end

  defp change_page(view, direction) do
    render_click(view, "page_change", %{"direction" => direction})
  end

  defp search(view, term) do
    view
    |> element("form")
    |> render_change(%{"q" => term})
  end

  defp page(view) do
    :sys.get_state(view.pid).socket.assigns.page
  end

  defp titles(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("tbody tr td:first-child a")
    |> Enum.map(&String.trim(Floki.text(&1)))
  end
end
