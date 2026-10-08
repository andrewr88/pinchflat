defmodule Pinchflat.Lifecycle.Notifications.SourceNotificationsTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Lifecycle.Notifications.SourceNotifications

  @apprise_servers ["server_1", "server_2"]

  describe "send_new_media_notification_for_media_items/3" do
    test "counts the media items that are pending download" do
      source = source_fixture()
      media_items = [media_item_fixture(%{source_id: source.id, media_filepath: nil})]

      expect(AppriseRunnerMock, :run, fn servers, opts ->
        assert servers == @apprise_servers

        assert opts == [
                 title: "[Pinchflat] New media found",
                 body: "Found 1 new media item for #{source.custom_name}. Downloading them now"
               ]

        {:ok, ""}
      end)

      assert :ok =
               SourceNotifications.send_new_media_notification_for_media_items(@apprise_servers, source, media_items)
    end

    test "counts the media items that are downloaded" do
      source = source_fixture()

      media_items = [
        media_item_fixture(%{source_id: source.id, media_filepath: "file.mp4"}),
        media_item_fixture(%{source_id: source.id, media_filepath: nil})
      ]

      expect(AppriseRunnerMock, :run, fn _servers, opts ->
        assert Keyword.get(opts, :body) =~ "Found 2 new media items for"

        {:ok, ""}
      end)

      SourceNotifications.send_new_media_notification_for_media_items(@apprise_servers, source, media_items)
    end

    test "doesn't count media items that won't be downloaded" do
      source = source_fixture()

      media_items = [
        media_item_fixture(%{source_id: source.id, media_filepath: nil}),
        media_item_fixture(%{source_id: source.id, prevent_download: true, media_filepath: nil})
      ]

      expect(AppriseRunnerMock, :run, fn _servers, opts ->
        assert Keyword.get(opts, :body) =~ "Found 1 new media item for"

        {:ok, ""}
      end)

      SourceNotifications.send_new_media_notification_for_media_items(@apprise_servers, source, media_items)
    end

    test "only counts the given media items" do
      source = source_fixture()
      media_items = [media_item_fixture(%{source_id: source.id, media_filepath: nil})]
      media_item_fixture(%{source_id: source.id, media_filepath: nil})

      expect(AppriseRunnerMock, :run, fn _servers, opts ->
        assert Keyword.get(opts, :body) =~ "Found 1 new media item for"

        {:ok, ""}
      end)

      SourceNotifications.send_new_media_notification_for_media_items(@apprise_servers, source, media_items)
    end

    test "counts lots of media items" do
      source = source_fixture()
      media_items = [media_item_fixture(%{source_id: source.id, media_filepath: nil})]
      # There are too many to fit into a single database query. Only the media items that exist are counted
      missing_media_items = Enum.map(1..50_000, &%MediaItem{id: -&1})

      expect(AppriseRunnerMock, :run, fn _servers, opts ->
        assert Keyword.get(opts, :body) =~ "Found 1 new media item for"

        {:ok, ""}
      end)

      SourceNotifications.send_new_media_notification_for_media_items(
        @apprise_servers,
        source,
        missing_media_items ++ media_items
      )
    end

    test "does not send a notification without any media items to count" do
      source = source_fixture()
      media_item_fixture(%{source_id: source.id, media_filepath: nil})

      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      assert :ok = SourceNotifications.send_new_media_notification_for_media_items(@apprise_servers, source, [])
    end

    test "does not send a notification if the source is set to not download media" do
      source = source_fixture(%{download_media: false})

      media_items = [
        media_item_fixture(%{source_id: source.id, media_filepath: nil}),
        media_item_fixture(%{source_id: source.id, media_filepath: "file.mp4"})
      ]

      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      SourceNotifications.send_new_media_notification_for_media_items(@apprise_servers, source, media_items)
    end
  end

  describe "send_new_media_notification/3" do
    test "sends a notification when count is positive" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, fn servers, opts ->
        assert servers == @apprise_servers

        assert opts == [
                 title: "[Pinchflat] New media found",
                 body: "Found 1 new media item for #{source.custom_name}. Downloading them now"
               ]

        {:ok, ""}
      end)

      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 1)
    end

    test "does not send a notification when count not positive" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 0)
      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, -1)
    end

    test "uses the plural for more than one media item" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, fn _servers, opts ->
        assert Keyword.get(opts, :body) == "Found 3 new media items for #{source.custom_name}. Downloading them now"

        {:ok, ""}
      end)

      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 3)
    end

    # The command runner has already logged the command's output at the error level
    test "logs which source the notification failed for" do
      source = source_fixture()
      expect(AppriseRunnerMock, :run, fn _, _ -> {:error, "apprise output"} end)

      log =
        capture_notification_log(fn -> SourceNotifications.send_new_media_notification(@apprise_servers, source, 1) end)

      assert log =~ "[error]"
      assert log =~ "source #{source.id}"
      refute log =~ "apprise output"
    end

    test "doesn't log an error if there are no notification servers" do
      source = source_fixture()
      expect(AppriseRunnerMock, :run, fn _, _ -> {:error, :no_servers} end)

      log = capture_notification_log(fn -> SourceNotifications.send_new_media_notification(nil, source, 1) end)

      refute log =~ "[error]"
    end
  end

  # The test env only logs critical messages so let this module's logging through. Returns the log
  # and checks that sending a notification always returns :ok
  defp capture_notification_log(fun) do
    Logger.put_module_level(SourceNotifications, :all)
    on_exit(fn -> Logger.delete_module_level(SourceNotifications) end)

    capture_log(fn -> assert :ok = fun.() end)
  end
end
