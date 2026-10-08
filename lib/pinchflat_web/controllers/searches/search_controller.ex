defmodule PinchflatWeb.Searches.SearchController do
  use PinchflatWeb, :controller

  alias Pinchflat.Media

  def show(conn, params) do
    # A query string like `?q[]=term` is parsed into a list
    search_term = if is_binary(params["q"]), do: params["q"], else: ""
    search_results = Media.search(search_term)

    render(conn, :show, search_term: search_term, search_results: search_results)
  end
end
