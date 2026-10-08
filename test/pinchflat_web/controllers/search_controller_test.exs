defmodule PinchflatWeb.SearchControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures

  describe "show search" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/search")
      assert html_response(conn, 200) =~ "Results"
    end

    test "shows matching media with the search term highlighted", %{conn: conn} do
      media_item = media_item_fixture(%{title: "The quick brown fox"})
      _other_media_item = media_item_fixture(%{title: "A lazy dog"})

      html = conn |> get(~p"/search?#{[q: "quick"]}") |> html_response(200)
      document = Floki.parse_document!(html)

      assert [result] = Floki.find(document, "tbody tr")
      assert Floki.attribute(result, "a", "href") == [~p"/sources/#{media_item.source_id}/media/#{media_item.id}"]
      assert highlights(document) == ["quick"]
      refute html =~ "A lazy dog"
    end

    # The excerpt is a snippet of the title followed by one of the description. Snippets are about 20 characters
    # around the match, so the description is kept short enough to be shown in full
    test "escapes the media's title and description", %{conn: conn} do
      media_item_fixture(%{title: "<script>alert(1)</script> quick", description: "<i>quick</i>"})

      html = conn |> get(~p"/search?#{[q: "quick"]}") |> html_response(200)
      document = Floki.parse_document!(html)

      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt; quick"
      assert html =~ "&lt;i&gt;"
      assert Floki.find(document, "tbody script") == []
      assert Floki.find(document, "tbody i") == []
    end

    # The excerpt's highlights are marked in its text, so text that looks like a marker mustn't become markup
    test "shows highlight markers in the media's title and description as text", %{conn: conn} do
      media_item_fixture(%{title: "quick [PF_HIGHLIGHT]", description: "[/PF_HIGHLIGHT] quick"})

      html = conn |> get(~p"/search?#{[q: "quick"]}") |> html_response(200)
      document = Floki.parse_document!(html)

      assert highlights(document) == ["quick", "quick"]
      assert [excerpt] = Floki.find(document, "tbody tr td:nth-child(2)")
      assert normalized_text(excerpt) == "quick [PF_HIGHLIGHT] [/PF_HIGHLIGHT] quick"
    end

    # A query string like `?q[]=term` is parsed into a list
    test "treats a search term that isn't a string as blank", %{conn: conn} do
      media_item_fixture(%{title: "The quick brown fox"})

      html = conn |> get("/search?q[]=quick") |> html_response(200)

      assert html =~ "No results found"
    end
  end

  defp highlights(document) do
    document
    |> Floki.find("tbody span.font-bold.italic")
    |> Enum.map(&normalized_text/1)
  end

  defp normalized_text(html_tree) do
    html_tree
    |> Floki.text()
    |> String.split()
    |> Enum.join(" ")
  end
end
