defmodule PinchflatWeb.CustomComponents.TextComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PinchflatWeb.CustomComponents.TextComponents

  describe "render_description/1" do
    test "links URLs" do
      html = render_description("See https://example.com/a?b=c or http://example.com for more")

      assert links(html) == [
               {"https://example.com/a?b=c", "https://example.com/a?b=c"},
               {"http://example.com", "http://example.com"}
             ]

      assert text(html) == "See https://example.com/a?b=c or http://example.com for more"
    end

    test "doesn't link text that just starts with http" do
      for description <- ["http server tips", "https is great", "http:// isn't a URL"] do
        html = render_description(description)

        assert {description, links(html)} == {description, []}
        assert text(html) == description
      end
    end
  end

  defp render_description(text) do
    render_component(&TextComponents.render_description/1, text: text)
  end

  defp links(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("a")
    |> Enum.map(fn link -> {link |> Floki.attribute("href") |> List.first(), String.trim(Floki.text(link))} end)
  end

  defp text(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.text(sep: " ")
    |> String.split()
    |> Enum.join(" ")
  end
end
