defmodule PinchflatWeb.Pages.StatsLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Profiles
  alias Pinchflat.Pages.StatsLive

  describe "initial rendering" do
    test "shows the stats", %{conn: conn} do
      _media_profile = media_profile_fixture()
      _media_item = media_item_fixture(media_size_bytes: 1_024)
      _media_item = media_item_fixture(media_size_bytes: 1_024)
      _pending_media_item = media_item_fixture(media_filepath: nil, media_size_bytes: 1_024)

      {:ok, _view, html} = live_isolated(conn, StatsLive, session: %{})

      # Each media item fixture also creates a source and a media profile
      assert stats_text(html) == "Media Profiles 4 Sources 3 Downloads 2 Library Size 2.0 KB"
    end

    # They're hidden everywhere else while they're being deleted
    test "doesn't count media profiles and sources that are being deleted", %{conn: conn} do
      media_profile = media_profile_fixture()
      _source = source_fixture(media_profile_id: media_profile.id)
      _source_being_deleted = source_fixture(media_profile_id: media_profile.id, marked_for_deletion_at: now())

      media_profile_being_deleted = media_profile_fixture()
      _source_on_profile_being_deleted = source_fixture(media_profile_id: media_profile_being_deleted.id)
      {:ok, _} = Profiles.update_media_profile(media_profile_being_deleted, %{marked_for_deletion_at: now()})

      {:ok, _view, html} = live_isolated(conn, StatsLive, session: %{})

      # Each source fixture also creates a media profile, which is why there are 4 of them
      assert stats_text(html) == "Media Profiles 4 Source 1 Downloads 0 Library Size 0.0 B"
    end
  end

  describe "job:state events" do
    test "reloads the stats on the scheduled reload", %{conn: conn} do
      {:ok, view, html} = live_isolated(conn, StatsLive, session: %{})
      assert stats_text(html) == "Media Profiles 0 Sources 0 Downloads 0 Library Size 0.0 B"

      _media_item = media_item_fixture(media_size_bytes: 1_024)
      for _ <- 1..3, do: PinchflatWeb.Endpoint.broadcast("job:state", "change", nil)

      assert reload_pending?(view)
      assert stats_text(render(view)) == "Media Profiles 0 Sources 0 Downloads 0 Library Size 0.0 B"

      send(view.pid, :reload)

      refute reload_pending?(view)
      assert stats_text(render(view)) == "Media Profile 1 Source 1 Download 1 Library Size 1.0 KB"
    end
  end

  defp stats_text(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.text(sep: " ")
    |> String.split()
    |> Enum.join(" ")
  end

  defp reload_pending?(view) do
    :sys.get_state(view.pid).socket.assigns.reload_pending
  end
end
