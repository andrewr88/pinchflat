defmodule Pinchflat.HTTP.HTTPClientTest do
  use Pinchflat.DataCase

  alias Pinchflat.HTTP.HTTPClient

  describe "get/3" do
    test "returns a non-ASCII body unchanged" do
      body = "Pinchflat ✓ café"
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen_socket)

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listen_socket)
          {:ok, _request} = :gen_tcp.recv(socket, 0)
          response = "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
          :ok = :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)
        end)

      assert {:ok, ^body} = HTTPClient.get("http://127.0.0.1:#{port}/")

      Task.await(server)
    end
  end
end
