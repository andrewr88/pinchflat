defmodule PinchflatWeb.Searches.SearchHTML do
  use PinchflatWeb, :html

  embed_templates "search_html/*"

  @doc """
  Highlight search terms in a string of text. They're wrapped in the STX and ETX control
  characters, as in the `matching_search_term` of `Pinchflat.Media.search/2`'s results
  """
  attr :text, :string, required: true

  def highlight_search_terms(assigns) do
    split_string = String.split(assigns.text, ~r{[\x02\x03]}, include_captures: true)
    assigns = assign(assigns, split_string: split_string)

    ~H"""
    <%= for fragment <- @split_string do %>
      {render_fragment(fragment)}
    <% end %>
    """
  end

  defp render_fragment("\x02"), do: raw(~s(<span class="font-bold italic">))
  defp render_fragment("\x03"), do: raw("</span>")
  defp render_fragment(text), do: text
end
