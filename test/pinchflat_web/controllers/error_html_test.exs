defmodule PinchflatWeb.ErrorHTMLTest do
  use PinchflatWeb.ConnCase, async: false

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template

  test "renders 404.html" do
    assert render_to_string(PinchflatWeb.ErrorHTML, "404", "html", []) =~ "404 (not found)"
  end

  test "renders 500.html" do
    assert render_to_string(PinchflatWeb.ErrorHTML, "500", "html", []) =~ "Internal Server Error"
  end

  # Error pages render inside the app layout, but requests that don't go through
  # the :browser pipeline (eg: podcast feeds, unmatched routes) never fetch the flash
  describe "error pages rendered by the endpoint" do
    test "renders a 404 for the feed of a source that doesn't exist", %{conn: conn} do
      {404, _headers, body} =
        assert_error_sent(404, fn -> get(conn, ~p"/sources/#{Ecto.UUID.generate()}/feed") end)

      assert body =~ "404 (not found)"
    end

    test "renders a 404 when streaming media that doesn't exist", %{conn: conn} do
      {404, _headers, body} =
        assert_error_sent(404, fn -> get(conn, ~p"/media/#{Ecto.UUID.generate()}/stream") end)

      assert body =~ "404 (not found)"
    end

    test "renders a 404 for routes that don't exist", %{conn: conn} do
      conn = get(conn, "/does-not-exist")

      assert html_response(conn, 404) =~ "404 (not found)"
    end

    test "renders a 404 within the app layout on browser routes", %{conn: conn} do
      {404, _headers, body} = assert_error_sent(404, fn -> get(conn, ~p"/sources/999999") end)

      assert body =~ "404 (not found)"
      assert body =~ "Search all media..."
    end
  end
end
