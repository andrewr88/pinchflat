defmodule PinchflatWeb.MediaItemControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Downloading.MediaDownloadWorker

  describe "show media" do
    setup [:create_media_item]

    test "renders the page", %{conn: conn, media_item: media_item} do
      conn = get(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}")

      assert html_response(conn, 200) =~ "#{media_item.title}"
    end

    test "renders the page when the media item has no description", %{conn: conn} do
      media_item = media_item_with_attachments(%{description: nil})
      conn = get(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}")

      assert html_response(conn, 200) =~ "#{media_item.title}"
    end

    # The title comes from the remote source, so it mustn't be able to break out of the copy button's JavaScript
    test "copies the media item's JSON without putting it in the click handler", %{conn: conn} do
      media_item = media_item_fixture(%{title: ~s|x`${alert(1)}` '"<>|})

      html = conn |> get(~p"/sources/#{media_item.source_id}/media/#{media_item}") |> html_response(200)
      [copy_json] = html |> Floki.parse_document!() |> Floki.find("[data-json]")
      [click_handler] = Floki.attribute(copy_json, "x-on:click")

      assert click_handler =~ "$el.dataset.json"
      refute click_handler =~ media_item.media_id
      refute click_handler =~ "alert"
      assert Floki.attribute(copy_json, "data-json") == [pretty_json(Repo.reload!(media_item))]
      assert html =~ ~s|x`${alert(1)}` &#39;\\&quot;&lt;&gt;|
    end

    test "previews the media with its MIME type", %{conn: conn} do
      media_item = media_item_with_attachments()
      webm_filepath = String.replace_suffix(media_item.media_filepath, ".mp4", ".WEBM")
      File.rename!(media_item.media_filepath, webm_filepath)
      Repo.update!(Ecto.Changeset.change(media_item, media_filepath: webm_filepath))

      html = conn |> get(~p"/sources/#{media_item.source_id}/media/#{media_item}") |> html_response(200)

      assert [source] = html |> Floki.parse_document!() |> Floki.find("video source")
      assert Floki.attribute(source, "type") == ["video/webm"]
    end

    test "previews audio in an audio player", %{conn: conn} do
      media_item = media_item_with_attachments()
      flac_filepath = String.replace_suffix(media_item.media_filepath, ".mp4", ".flac")
      File.rename!(media_item.media_filepath, flac_filepath)
      Repo.update!(Ecto.Changeset.change(media_item, media_filepath: flac_filepath))

      html = conn |> get(~p"/sources/#{media_item.source_id}/media/#{media_item}") |> html_response(200)
      document = Floki.parse_document!(html)

      assert [] = Floki.find(document, "video")
      assert [source] = Floki.find(document, "audio source")
      assert Floki.attribute(source, "type") == ["audio/flac"]
    end

    test "returns 404 if the media item doesn't exist", %{conn: conn, media_item: media_item} do
      assert_error_sent 404, fn -> get(conn, ~p"/sources/#{media_item.source_id}/media/0") end
    end
  end

  describe "edit media" do
    setup [:create_media_item]

    test "renders form for editing chosen media_item", %{conn: conn, media_item: media_item} do
      conn = get(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}/edit")

      assert html_response(conn, 200) =~ "Editing"
    end

    test "returns 404 if the media item doesn't exist", %{conn: conn, media_item: media_item} do
      assert_error_sent 404, fn -> get(conn, ~p"/sources/#{media_item.source_id}/media/0/edit") end
    end
  end

  describe "update media" do
    setup [:create_media_item]

    test "redirects when data is valid", %{conn: conn, media_item: media_item} do
      update_attrs = %{prevent_download: true}

      conn = put(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}", media_item: update_attrs)
      assert redirected_to(conn) == ~p"/sources/#{media_item.source_id}/media/#{media_item}"
      assert Repo.reload!(media_item).prevent_download
    end

    test "renders errors when data is invalid", %{conn: conn, media_item: media_item} do
      conn =
        put(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}", media_item: %{prevent_download: "maybe"})

      assert html_response(conn, 200) =~ "Editing"
    end

    test "saves each field on the form", %{conn: conn, media_item: media_item} do
      form_params = %{"prevent_download" => "true", "prevent_culling" => "true"}

      # Fails when a field is added to the form, as a reminder to make sure it can be saved
      edit_html = conn |> get(~p"/sources/#{media_item.source_id}/media/#{media_item}/edit") |> html_response(200)
      assert form_field_names(edit_html, "media_item") == Enum.sort(Map.keys(form_params))

      put(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}", media_item: form_params)

      assert %MediaItem{prevent_download: true, prevent_culling: true} = Repo.reload!(media_item)
    end

    # The app serves the files at these paths (some publicly, eg: streaming) and deletes them along with the media item
    test "doesn't set the media item's file paths from the request", %{conn: conn, media_item: media_item} do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:txt)

      params =
        MediaItem.filepath_attributes()
        |> Map.new(&{to_string(&1), filepath})
        |> Map.put("subtitle_filepaths", [["en", filepath]])
        |> Map.put("prevent_download", "true")

      put(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}", media_item: params)

      updated_media_item = Repo.reload!(media_item)

      assert updated_media_item.prevent_download

      assert Map.take(updated_media_item, MediaItem.filepath_attributes()) ==
               Map.take(media_item, MediaItem.filepath_attributes())
    end
  end

  describe "delete media" do
    setup do
      media_item = media_item_with_attachments()
      stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

      %{media_item: media_item}
    end

    test "the media item not is deleted", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      assert Repo.reload!(media_item)
    end

    test "the files are deleted", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      refute File.exists?(media_item.media_filepath)
    end

    test "redirects to the source page", %{conn: conn, media_item: media_item} do
      conn = delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      assert redirected_to(conn) == ~p"/sources/#{media_item.source_id}"
    end

    test "doesn't prevent re-download by default", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      media_item = Repo.reload(media_item)

      refute media_item.prevent_download
    end

    test "can optionally prevent re-download", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}?prevent_download=true")

      media_item = Repo.reload(media_item)

      assert media_item.prevent_download
    end

    test "succeeds when the media item has no files", %{conn: conn} do
      media_item = media_item_fixture(%{media_filepath: nil})

      conn = delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}?prevent_download=true")

      assert redirected_to(conn) == ~p"/sources/#{media_item.source_id}"
      assert conn.assigns[:flash]["info"] == "Files deleted successfully."
      assert Repo.reload!(media_item).prevent_download
    end

    test "returns 404 if the media item doesn't exist", %{conn: conn, media_item: media_item} do
      assert_error_sent 404, fn -> delete(conn, ~p"/sources/#{media_item.source_id}/media/0") end
    end
  end

  describe "force_download" do
    test "enqueues download task", %{conn: conn} do
      media_item = media_item_fixture()

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "doesn't freak out if the task is a duplicate", %{conn: conn} do
      media_item = media_item_fixture()

      MediaDownloadWorker.kickoff_with_task(media_item, %{force: true})

      post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "forces a download even if one wouldn't normally run", %{conn: conn} do
      media_item = media_item_fixture(%{media_filepath: nil})

      post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")
      assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id, "force" => true})
    end

    test "redirects to the show page", %{conn: conn} do
      media_item = media_item_fixture()

      conn = post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")

      assert redirected_to(conn) == ~p"/sources/#{media_item.source_id}/media/#{media_item.id}"
    end

    test "returns 404 if the media item doesn't exist", %{conn: conn} do
      media_item = media_item_fixture()

      assert_error_sent 404, fn -> post(conn, ~p"/sources/#{media_item.source_id}/media/0/force_download") end
      assert [] = all_enqueued(worker: MediaDownloadWorker)
    end
  end

  describe "streaming media" do
    test "returns 404 if the media isn't found", %{conn: conn} do
      media_item = media_item_fixture()
      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 404
    end

    # Deleting an item's files nils its filepath, but the stream URL lives on in podcast feeds
    test "returns 404 if the media's files have been deleted", %{conn: conn} do
      media_item = media_item_fixture(%{media_filepath: nil})
      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 404
    end

    test "encodes the title in the content disposition", %{conn: conn} do
      media_item = media_item_with_attachments(%{title: ~s(Say "hi"\r\nto Zoë \\o/)})
      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      expected =
        ~s(inline; filename="Say _hi_to Zo_ _o/"; ) <>
          "filename*=UTF-8''Say%20%22hi%22%0D%0Ato%20Zo%C3%AB%20%5Co%2F"

      assert conn.status == 200
      assert {"content-disposition", expected} in conn.resp_headers
    end

    test "automatically sets the content type", %{conn: conn} do
      media_item = media_item_with_attachments()
      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert {"content-type", "video/mp4; charset=utf-8"} in conn.resp_headers
    end

    # MIME doesn't know some of the containers yt-dlp produces, eg: Matroska
    test "sets the content type for containers that MIME doesn't know", %{conn: conn} do
      media_item = media_item_with_attachments()
      mkv_filepath = String.replace_suffix(media_item.media_filepath, ".mp4", ".mkv")
      File.rename!(media_item.media_filepath, mkv_filepath)
      Repo.update!(Ecto.Changeset.change(media_item, media_filepath: mkv_filepath))

      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert {"content-type", "video/x-matroska; charset=utf-8"} in conn.resp_headers
    end

    test "sets the content length", %{conn: conn} do
      media_item = media_item_with_attachments()
      filesize = File.stat!(media_item.media_filepath).size

      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert {"content-length", to_string(filesize)} in conn.resp_headers
    end
  end

  describe "streaming media when range is valid" do
    setup do
      media_item = media_item_with_attachments(%{title: "My Video"})

      %{media_item: media_item}
    end

    test "sets the correct status and headers", %{conn: conn, media_item: media_item} do
      filesize = File.stat!(media_item.media_filepath).size

      conn =
        conn
        |> put_req_header("range", "bytes=0-100")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 206
      assert {"content-range", "bytes 0-100/#{filesize}"} in conn.resp_headers
      assert {"content-length", "101"} in conn.resp_headers
      assert {"content-disposition", ~s(inline; filename="My Video"; filename*=UTF-8''My%20Video)} in conn.resp_headers
    end

    test "streams the specified range", %{conn: conn, media_item: media_item} do
      conn =
        conn
        |> put_req_header("range", "bytes=0-100")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert byte_size(conn.resp_body) == 101
    end

    test "supports range offsets", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)
      expected = String.slice(contents, 100..200)

      conn =
        conn
        |> put_req_header("range", "bytes=100-200")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == expected
    end

    test "returns as expected if the requested range is larger than the file", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)
      filesize = File.stat!(media_item.media_filepath).size

      conn =
        conn
        |> put_req_header("range", "bytes=0-#{filesize * 10}")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == contents
      assert {"content-range", "bytes 0-#{filesize - 1}/#{filesize}"} in conn.resp_headers
      assert {"content-length", to_string(filesize)} in conn.resp_headers
    end

    test "supports endless ranges", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)

      conn =
        conn
        |> put_req_header("range", "bytes=0-")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == contents
    end

    test "supports endless ranges with offsets", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)
      {_, expected} = String.split_at(contents, 100)

      conn =
        conn
        |> put_req_header("range", "bytes=100-")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == expected
    end

    test "supports suffix ranges and ranges at the edges of the file", %{media_item: media_item} do
      contents = File.read!(media_item.media_filepath)
      size = byte_size(contents)

      # {range header, first byte, last byte}
      cases = [
        {"bytes=-500", size - 500, size - 1},
        {"bytes=-#{size * 10}", 0, size - 1},
        {"bytes=#{size - 1}-", size - 1, size - 1},
        {"bytes=0-0", 0, 0}
      ]

      for {range, first, last} <- cases do
        conn = stream_with_range(media_item, range)
        length = last - first + 1

        assert {range, conn.status} == {range, 206}
        assert {"content-range", "bytes #{first}-#{last}/#{size}"} in conn.resp_headers
        assert {"content-length", to_string(length)} in conn.resp_headers
        assert conn.resp_body == binary_part(contents, first, length)
      end
    end
  end

  describe "streaming media when range is unsatisfiable" do
    setup do
      media_item = media_item_with_attachments()

      %{media_item: media_item}
    end

    test "returns a 416 with the file size", %{media_item: media_item} do
      size = File.stat!(media_item.media_filepath).size

      for range <- ["bytes=#{size}-", "bytes=#{size}-#{size + 100}", "bytes=100-50", "bytes=-0"] do
        conn = stream_with_range(media_item, range)

        assert {range, conn.status} == {range, 416}
        assert {"content-range", "bytes */#{size}"} in conn.resp_headers
      end
    end

    test "returns a 416 for any range on an empty file", %{media_item: media_item} do
      File.write!(media_item.media_filepath, "")

      for range <- ["bytes=0-", "bytes=0-100", "bytes=-500"] do
        conn = stream_with_range(media_item, range)

        assert {range, conn.status} == {range, 416}
        assert {"content-range", "bytes */0"} in conn.resp_headers
      end
    end
  end

  describe "streaming media when range is invalid or not present" do
    setup do
      media_item = media_item_with_attachments(%{title: "My Video"})

      %{media_item: media_item}
    end

    test "sets the correct status and headers", %{conn: conn, media_item: media_item} do
      filesize = File.stat!(media_item.media_filepath).size

      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 200
      assert {"content-length", to_string(filesize)} in conn.resp_headers
      assert {"content-range", "bytes 0-#{filesize - 1}/#{filesize}"} in conn.resp_headers
      assert {"content-disposition", ~s(inline; filename="My Video"; filename*=UTF-8''My%20Video)} in conn.resp_headers
    end

    test "streams the entire file", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)

      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == contents
    end

    test "doesn't blow up if the range header is invalid", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)

      conn =
        conn
        |> put_req_header("range", "bytes=-")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 200
      assert conn.resp_body == contents
    end

    test "serves the entire file if a range position isn't entirely a number", %{media_item: media_item} do
      contents = File.read!(media_item.media_filepath)

      for range <- ["bytes=10abc-", "bytes=10-20abc", "bytes=abc-20", "bytes=-abc"] do
        conn = stream_with_range(media_item, range)

        assert {range, conn.status} == {range, 200}
        assert conn.resp_body == contents
      end
    end
  end

  defp create_media_item(_) do
    media_item = media_item_fixture()
    %{media_item: media_item}
  end

  # The fields of a form's inputs, eg: "prevent_download" for `name="media_item[prevent_download]"`
  defp form_field_names(html, param_name) do
    ~r/name="#{param_name}\[(\w+)\]"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp stream_with_range(media_item, range) do
    build_conn()
    |> put_req_header("range", range)
    |> get(~p"/media/#{media_item.uuid}/stream")
  end

  # What the actions dropdown's "Copy JSON" copies
  defp pretty_json(record) do
    record
    |> Phoenix.json_library().encode!()
    |> Jason.Formatter.pretty_print()
  end
end
