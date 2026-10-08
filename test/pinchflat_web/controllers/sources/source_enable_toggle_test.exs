defmodule PinchflatWeb.Sources.SourceLive.SourceEnableToggleTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources
  alias PinchflatWeb.Sources.SourceLive.IndexTableLive
  alias PinchflatWeb.Sources.SourceLive.SourceEnableToggle

  describe "initial rendering" do
    test "renders a toggle in the on position if the source is enabled" do
      source = %{id: 1, enabled: true}

      html = render_component(SourceEnableToggle, %{id: :foo, source: source})

      # This is checking the Alpine attrs which is a good-enough proxy for the toggle position
      assert html =~ "{ enabled: true }"
    end

    test "renders a toggle in the off position if the source is disabled" do
      source = %{id: 1, enabled: false}

      html = render_component(SourceEnableToggle, %{id: :foo, source: source})

      assert html =~ "{ enabled: false }"
    end
  end

  # The toggle is rendered in the sources table
  describe "toggling" do
    test "enables the source", %{conn: conn} do
      source = source_fixture(enabled: false)
      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      view |> element("form.enabled_toggle_form") |> render_change(%{source: %{enabled: true}})

      assert Repo.reload!(source).enabled
    end

    # The table can be out of date. Like a source that's been deleted, it fails (and the table reloads)
    test "doesn't enable a source that's being deleted", %{conn: conn} do
      source = source_fixture(enabled: false)
      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      {:ok, _} = Sources.update_source(source, %{marked_for_deletion_at: now()})
      Process.flag(:trap_exit, true)

      catch_exit(view |> element("form.enabled_toggle_form") |> render_change(%{source: %{enabled: true}}))

      refute Repo.reload!(source).enabled
    end
  end

  defp create_session do
    %{
      "initial_sort_key" => :custom_name,
      "initial_sort_direction" => :asc,
      "results_per_page" => 10
    }
  end
end
