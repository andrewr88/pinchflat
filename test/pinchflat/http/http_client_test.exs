defmodule Pinchflat.HTTP.HTTPClientTest do
  use Pinchflat.DataCase

  alias Pinchflat.HTTP.HTTPClient

  describe "get/3" do
    test "returns a non-ASCII body unchanged" do
      body = "Pinchflat ✓ café"

      url =
        serve_once(fn ->
          "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
        end)

      assert {:ok, ^body} = HTTPClient.get(url)
    end

    test "returns an error with the status for an error response" do
      url = serve_once(fn -> "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n" end)

      assert {:error, "HTTP request failed with status code 404: Not Found"} = HTTPClient.get(url)
    end

    test "returns an error for a successful response other than a 200" do
      url = serve_once(fn -> "HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n" end)

      assert {:error, "HTTP request failed with status code 204: No Content"} = HTTPClient.get(url)
    end

    test "returns an error if the connection is refused" do
      assert {:error, "HTTP request failed: " <> _} = HTTPClient.get(refused_url())
    end

    test "returns an error if the response doesn't arrive in time" do
      url = serve_once(fn -> :no_response end)
      started_at = System.monotonic_time(:millisecond)

      assert {:error, "HTTP request failed: " <> reason} = HTTPClient.get(url, [], http_options: [timeout: 100])

      assert reason =~ "timeout"
      assert System.monotonic_time(:millisecond) - started_at < 2_000
    end

    # A server that never responds would take as long as the default to time out, so check what `:httpc` gets
    test "sets timeouts by default since `:httpc` otherwise never times out" do
      http_options = httpc_http_options(fn -> HTTPClient.get(refused_url()) end)

      assert http_options[:timeout] == 10_000
      assert http_options[:connect_timeout] == 5_000
    end

    test "keeps the defaults that the caller's HTTP options don't replace" do
      http_options =
        httpc_http_options(fn ->
          HTTPClient.get(refused_url(), [], http_options: [timeout: 100, autoredirect: false])
        end)

      assert http_options[:timeout] == 100
      assert http_options[:connect_timeout] == 5_000
      assert http_options[:autoredirect] == false
    end
  end

  # Serves one request on a local socket with whatever `response_fun` returns, or never responds if
  # that's `:no_response`. The server is linked to the test so it stops with it. Returns the URL to request
  defp serve_once(response_fun) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen_socket)

    Task.async(fn ->
      {:ok, socket} = :gen_tcp.accept(listen_socket)
      {:ok, _request} = :gen_tcp.recv(socket, 0)

      case response_fun.() do
        # Waits until the client gives up and closes the connection
        :no_response -> :gen_tcp.recv(socket, 0)
        response -> :ok = :gen_tcp.send(socket, response)
      end

      :gen_tcp.close(socket)
    end)

    "http://127.0.0.1:#{port}/"
  end

  # Nothing listens on the port once its socket is closed
  defp refused_url do
    {:ok, listen_socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen_socket)
    :ok = :gen_tcp.close(listen_socket)

    "http://127.0.0.1:#{port}/"
  end

  # Returns the HTTP options that `fun` calls `:httpc.request/4` with. A process can't trace its own
  # calls, so `fun` runs in another one
  defp httpc_http_options(fun) do
    Code.ensure_loaded!(:httpc)
    :erlang.trace_pattern({:httpc, :request, 4}, true, [])
    on_exit(fn -> :erlang.trace_pattern({:httpc, :request, 4}, false, []) end)

    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :run -> fun.()
        end
      end)

    :erlang.trace(pid, true, [:call])
    send(pid, :run)

    assert_receive {:trace, ^pid, :call, {:httpc, :request, [_method, _request, http_options, _opts]}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    http_options
  end
end
