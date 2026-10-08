defmodule PinchflatWeb.RouterTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  @auth_env_keys [:basic_auth_username, :basic_auth_password, :expose_feed_endpoints]

  setup do
    original_env = Map.new(@auth_env_keys, &{&1, Application.get_env(:pinchflat, &1)})
    on_exit(fn -> Enum.each(original_env, fn {key, value} -> Application.put_env(:pinchflat, key, value) end) end)

    Application.put_env(:pinchflat, :basic_auth_username, "user")
    Application.put_env(:pinchflat, :basic_auth_password, "pass")
    Application.put_env(:pinchflat, :expose_feed_endpoints, false)

    :ok
  end

  describe "the app's pages when basic auth is configured" do
    setup do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id)

      requests = [
        {:get, ~p"/"},
        {:get, ~p"/settings"},
        {:get, ~p"/app_info"},
        {:get, ~p"/download_logs"},
        {:get, "/dev/dashboard"},
        {:get, ~p"/sources"},
        {:get, ~p"/sources/#{source}"},
        {:get, ~p"/sources/#{source}/media/#{media_item}"},
        {:get, ~p"/media_profiles"},
        {:get, ~p"/search?#{[q: "term"]}"},
        {:put, ~p"/settings"},
        {:post, ~p"/settings/save_cookies"},
        {:delete, ~p"/sources/#{source}"}
      ]

      %{requests: requests, source: source}
    end

    test "require credentials", %{requests: requests, source: source} do
      for {method, path} <- requests do
        conn = dispatch(build_conn(), @endpoint, method, path, nil)

        assert {method, path, conn.status} == {method, path, 401}
        assert {"www-authenticate", ~s(Basic realm="Pinchflat")} in conn.resp_headers
      end

      refute Repo.reload!(source).marked_for_deletion_at
    end

    test "reject the wrong credentials", %{requests: requests} do
      for {method, path} <- requests do
        conn =
          build_conn()
          |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("user", "wrong"))
          |> dispatch(@endpoint, method, path, nil)

        assert {method, path, conn.status} == {method, path, 401}
      end
    end

    test "can be viewed with the right credentials", %{requests: requests} do
      for {:get, path} <- requests do
        conn = get(with_credentials(build_conn()), path)

        assert {path, conn.status} in [{path, 200}, {path, 302}]
      end
    end
  end

  describe "the health check when basic auth is configured" do
    test "doesn't require credentials", %{conn: conn} do
      conn = get(conn, ~p"/healthcheck")

      assert json_response(conn, 200) == %{"status" => "ok"}
    end
  end

  describe "feed and streaming routes when basic auth is configured" do
    setup do
      source = source_with_metadata_attachments()
      media_item = media_item_with_attachments(%{source_id: source.id})

      paths = [
        ~p"/sources/#{source.uuid}/feed" <> ".xml",
        ~p"/sources/#{source.uuid}/feed_image" <> ".jpg",
        ~p"/media/#{media_item.uuid}/episode_image" <> ".jpg",
        ~p"/media/#{media_item.uuid}/stream"
      ]

      %{paths: paths}
    end

    test "require credentials when the feed endpoints aren't exposed", %{paths: paths} do
      for path <- paths do
        conn = get(build_conn(), path)

        assert {path, conn.status} == {path, 401}
      end
    end

    test "can be accessed with credentials when the feed endpoints aren't exposed", %{paths: paths} do
      for path <- paths do
        conn = get(with_credentials(build_conn()), path)

        assert {path, conn.status} == {path, 200}
      end
    end

    test "don't require credentials when the feed endpoints are exposed", %{paths: paths} do
      Application.put_env(:pinchflat, :expose_feed_endpoints, true)

      for path <- paths do
        conn = get(build_conn(), path)

        assert {path, conn.status} == {path, 200}
      end
    end
  end

  describe "the OPML feed when basic auth is configured" do
    setup do
      %{opml_path: ~p"/sources/opml.xml?#{[route_token: Settings.get!(:route_token)]}"}
    end

    test "requires credentials and the route token when the feed endpoints aren't exposed", %{opml_path: opml_path} do
      assert get(build_conn(), opml_path).status == 401
      assert get(with_credentials(build_conn()), ~p"/sources/opml.xml").status == 401
      assert get(with_credentials(build_conn()), ~p"/sources/opml.xml?route_token=wrong").status == 401

      assert get(with_credentials(build_conn()), opml_path).status == 200
    end

    test "still requires the route token when the feed endpoints are exposed", %{opml_path: opml_path} do
      Application.put_env(:pinchflat, :expose_feed_endpoints, true)

      conn = get(build_conn(), ~p"/sources/opml.xml")
      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"

      assert get(build_conn(), opml_path).status == 200
    end
  end

  defp with_credentials(conn) do
    put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth("user", "pass"))
  end
end
