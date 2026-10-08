defmodule Pinchflat.HTTP.HTTPClient do
  @moduledoc """
  This module provides a simple interface for making HTTP requests.

  Made to be easily swappable with other HTTP clients. If you need more complexity
  or security, check out HTTPoison or Mint.
  """

  alias Pinchflat.HTTP.HTTPBehaviour

  @behaviour HTTPBehaviour

  # `:httpc` never times out by default, so a server that stops responding would hang the caller
  @default_http_options [timeout: 10_000, connect_timeout: 5_000]

  @doc """
  Makes a GET request to the given URL and returns the response.

  NOTE: this can't be tested with Mox, so its test talks to a local socket. Its
  consumers are tested with the Mox mock instead.

  Additional Opts:
    - :http_options - HTTP options for `:httpc.request/4`. The `:timeout` (10 seconds)
      and `:connect_timeout` (5 seconds) defaults can be replaced here. All other opts
      are passed to `:httpc.request/4` as its options, except `:body_format`: the body
      is always returned as the binary that was received.

  Returns {:ok, String.t()} | {:error, String.t()}
  """
  @impl HTTPBehaviour
  def get(url, headers \\ [], opts \\ []) do
    headers = parse_headers(headers)
    {http_options, opts} = Keyword.pop(opts, :http_options, [])
    http_options = Keyword.merge(@default_http_options, http_options)
    # The default (a charlist of the body's bytes) would double-encode non-ASCII UTF-8 in `to_string/1`
    opts = Keyword.put(opts, :body_format, :binary)

    case :httpc.request(:get, {url, headers}, http_options, opts) do
      {:ok, {{_version, 200, _reason_phrase}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_version, status_code, reason_phrase}, _headers, _body}} ->
        {:error, "HTTP request failed with status code #{status_code}: #{reason_phrase}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp parse_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end
end
