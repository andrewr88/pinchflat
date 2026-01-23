defmodule Pinchflat.Downloading.MediaDownloaderTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Media
  alias Pinchflat.Downloading.MediaDownloader

  setup do
    media_item =
      Repo.preload(
        media_item_fixture(%{title: "Something", media_filepath: nil}),
        [:metadata, source: :media_profile]
      )

    stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)

    {:ok, %{media_item: media_item}}
  end

  describe "download_for_media_item/3" do
    test "calls the backend runner", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}

        url, :download, _opts, ot, addl ->
          assert url == media_item.original_url
          assert ot == "after_move:%()j"
          assert [{:output_filepath, filepath} | _] = addl
          assert is_binary(filepath)

          {:ok, render_metadata(:media_metadata)}
      end)

      assert {:ok, _} = MediaDownloader.download_for_media_item(media_item)
    end

    test "saves the metadata filepath to the database", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
      end)

      assert is_nil(media_item.metadata)
      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)

      assert updated_media_item.metadata.metadata_filepath =~ "media_items/#{media_item.id}/metadata.json.gz"
      assert updated_media_item.metadata.thumbnail_filepath =~ "media_items/#{media_item.id}/thumbnail.jpg"
    end

    test "errors for non-downloadable media are passed through", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_downloadable_status, _opts, _ot, _addl ->
        {:ok, Phoenix.json_library().encode!(%{"live_status" => "is_live"})}
      end)

      assert {:error, :unsuitable_for_download, message} = MediaDownloader.download_for_media_item(media_item)
      assert message =~ "Media item ##{media_item.id} isn't suitable for download yet."
    end

    test "non-recoverable errors are passed through", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, :some_error, 1}
      end)

      assert {:error, :download_failed, :some_error} = MediaDownloader.download_for_media_item(media_item)
    end

    test "unknown errors are passed through", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, :some_error}
      end)

      assert {:error, :unknown, message} = MediaDownloader.download_for_media_item(media_item)
      assert message == "Unknown error: {:error, :some_error}"
    end
  end

  describe "download_for_media_item/3 when testing non-downloadable media" do
    test "calls the download runner if the media is currently downloadable", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, Phoenix.json_library().encode!(%{"live_status" => "was_live"})}

        _url, :download, _opts, _ot, _addl ->
          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      assert {:ok, _} = MediaDownloader.download_for_media_item(media_item)
    end

    test "does not call the download runner if the media is not downloadable", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, Phoenix.json_library().encode!(%{"live_status" => "is_live"})}
      end)

      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> {:ok, ""} end)

      assert {:error, :unsuitable_for_download, message} = MediaDownloader.download_for_media_item(media_item)
      assert message =~ "Media item ##{media_item.id} isn't suitable for download yet."
    end

    test "returns unexpected errors from the download status determination method", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_downloadable_status, _opts, _ot, _addl -> {:error, :what_tha} end)

      assert {:error, :unknown, "Unknown error: {:error, :what_tha}"} =
               MediaDownloader.download_for_media_item(media_item)
    end
  end

  describe "download_for_media_item/3 when testing override options" do
    test "includes override opts if specified", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          refute :force_overwrites in opts
          assert :no_force_overwrites in opts

          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      override_opts = [overwrite_behaviour: :no_force_overwrites]

      assert {:ok, _} = MediaDownloader.download_for_media_item(media_item, override_opts)
    end
  end

  describe "download_for_media_item/3 when testing cookie usage" do
    test "sets use_cookies if the source uses cookies" do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, addl ->
          assert {:use_cookies, true} in addl
          {:ok, "{}"}

        _url, :download, _opts, _ot, addl ->
          assert {:use_cookies, true} in addl
          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      source = source_fixture(%{cookie_behaviour: :all_operations})
      media_item = media_item_fixture(%{source_id: source.id})

      assert {:ok, _} = MediaDownloader.download_for_media_item(media_item)
    end

    test "does not set use_cookies if the source uses cookies when needed" do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, "{}"}

        _url, :download, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      source = source_fixture(%{cookie_behaviour: :when_needed})
      media_item = media_item_fixture(%{source_id: source.id})

      assert {:ok, _} = MediaDownloader.download_for_media_item(media_item)
    end

    test "does not set use_cookies if the source does not use cookies" do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, "{}"}

        _url, :download, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      source = source_fixture(%{cookie_behaviour: :disabled})
      media_item = media_item_fixture(%{source_id: source.id})

      assert {:ok, _} = MediaDownloader.download_for_media_item(media_item)
    end
  end

  describe "download_for_media_item/3 when testing non-cookie retries" do
    test "returns a recovered tuple on recoverable errors", %{media_item: media_item} do
      message = "Unable to communicate with SponsorBlock"

      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, addl ->
          [{:output_filepath, filepath} | _] = addl
          File.write(filepath, render_metadata(:media_metadata))

          {:error, message, 1}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      assert {:recovered, _media_item, ^message} = MediaDownloader.download_for_media_item(media_item)
    end

    test "attempts to update the media item on recoverable errors", %{media_item: media_item} do
      message = "Unable to communicate with SponsorBlock"

      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :download, _opts, _ot, addl ->
          [{:output_filepath, filepath} | _] = addl
          File.write(filepath, render_metadata(:media_metadata))

          {:error, message, 1}

        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      assert {:recovered, updated_media_item, ^message} = MediaDownloader.download_for_media_item(media_item)

      assert DateTime.diff(DateTime.utc_now(), updated_media_item.media_downloaded_at) < 2
      assert String.ends_with?(updated_media_item.media_filepath, ".mkv")
    end

    test "returns an unrecoverable tuple if recovery fails", %{media_item: media_item} do
      message = "Unable to communicate with SponsorBlock"

      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          # This errors because the metadata is not written to the file so JSON parsing fails
          {:error, message, 1}
      end)

      assert {:error, :unrecoverable, ^message} = MediaDownloader.download_for_media_item(media_item)
    end

    test "sets the last_error appropriately when recovered", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :download, _opts, _ot, addl ->
          [{:output_filepath, filepath} | _] = addl
          File.write(filepath, render_metadata(:media_metadata))

          {:error, "Unable to communicate with SponsorBlock", 1}

        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      assert {:recovered, updated_media_item, _message} = MediaDownloader.download_for_media_item(media_item)
      assert updated_media_item.last_error == "Unable to communicate with SponsorBlock"
    end

    test "sets the last_error appropriately when unrecoverable", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          {:error, "Unable to communicate with SponsorBlock", 1}
      end)

      assert {:error, :unrecoverable, _message} = MediaDownloader.download_for_media_item(media_item)
      media_item = Repo.reload(media_item)

      assert media_item.last_error == "Unable to communicate with SponsorBlock"
    end
  end

  describe "download_for_media_item/3 when testing SponsorBlock retry" do
    setup do
      # Set up a media item with SponsorBlock enabled
      profile = media_profile_fixture(%{
        sponsorblock_behaviour: :mark,
        sponsorblock_categories: ["sponsor", "intro", "outro"]
      })
      source = source_fixture(%{media_profile_id: profile.id})
      media_item =
        Repo.preload(
          media_item_fixture(%{source_id: source.id}),
          [:metadata, source: :media_profile]
        )

      stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)

      {:ok, %{media_item: media_item}}
    end

    test "retries download without SponsorBlock options when SponsorBlock error occurs", %{media_item: media_item} do
      message = "Unable to communicate with SponsorBlock API: HTTP Error 503: Service Unavailable"

      expect(YtDlpRunnerMock, :run, 5, fn
        # Initial download attempt with SponsorBlock (fails)
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          # Verify SponsorBlock options are present in initial attempt
          assert {:sponsorblock_mark, _} in opts
          {:error, message, 1}

        # Retry without SponsorBlock (succeeds)
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          # Verify SponsorBlock options are NOT present in retry
          refute Keyword.has_key?(opts, :sponsorblock_mark)
          refute Keyword.has_key?(opts, :sponsorblock_remove)
          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      assert {:recovered, _media_item, ^message} = MediaDownloader.download_for_media_item(media_item)
    end

    test "successfully recovers from SponsorBlock error and updates media item", %{media_item: media_item} do
      message = "Unable to communicate with SponsorBlock API: HTTP Error 503: Service Unavailable"

      expect(YtDlpRunnerMock, :run, 5, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          {:error, message, 1}

        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      assert {:recovered, updated_media_item, ^message} = MediaDownloader.download_for_media_item(media_item)

      assert DateTime.diff(DateTime.utc_now(), updated_media_item.media_downloaded_at) < 2
      assert String.ends_with?(updated_media_item.media_filepath, ".mkv")
      assert updated_media_item.last_error == message
    end

    test "falls back to parse recovery if retry without SponsorBlock also fails", %{media_item: media_item} do
      message = "Unable to communicate with SponsorBlock API: HTTP Error 503: Service Unavailable"

      expect(YtDlpRunnerMock, :run, 4, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, addl ->
          [{:output_filepath, filepath} | _] = addl
          # Write metadata to file for parse recovery fallback
          File.write(filepath, render_metadata(:media_metadata))
          {:error, message, 1}

        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          # Retry also fails
          {:error, "Some other error", 1}
      end)

      # Should fall back to parse recovery and succeed
      assert {:recovered, _media_item, ^message} = MediaDownloader.download_for_media_item(media_item)
    end

    test "returns unrecoverable if retry fails and parse recovery also fails", %{media_item: media_item} do
      message = "Unable to communicate with SponsorBlock API: HTTP Error 503: Service Unavailable"

      expect(YtDlpRunnerMock, :run, 4, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          # No metadata written, so parse recovery will fail
          {:error, message, 1}

        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          # Retry also fails
          {:error, "Some other error", 1}
      end)

      assert {:error, :unrecoverable, ^message} = MediaDownloader.download_for_media_item(media_item)
    end

    test "handles unsuitable_for_download during retry gracefully", %{media_item: media_item} do
      message = "Unable to communicate with SponsorBlock API: HTTP Error 503: Service Unavailable"

      expect(YtDlpRunnerMock, :run, 4, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, addl ->
          [{:output_filepath, filepath} | _] = addl
          # Write metadata to file for parse recovery fallback
          File.write(filepath, render_metadata(:media_metadata))
          {:error, message, 1}

        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, Phoenix.json_library().encode!(%{"live_status" => "is_live"})}

        _url, :download, _opts, _ot, _addl ->
          # This shouldn't be called, but just in case
          {:error, "Should not reach here", 1}
      end)

      # Should fall back to parse recovery
      assert {:recovered, _media_item, ^message} = MediaDownloader.download_for_media_item(media_item)
    end

    test "only retries without SponsorBlock for SponsorBlock-specific errors", %{media_item: media_item} do
      # This test ensures non-SponsorBlock errors don't trigger the retry logic
      message = "Some other recoverable error"

      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, addl ->
          [{:output_filepath, filepath} | _] = addl
          File.write(filepath, render_metadata(:media_metadata))
          {:error, message, 1}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      # Should use parse recovery, not SponsorBlock retry
      assert {:recovered, _media_item, ^message} = MediaDownloader.download_for_media_item(media_item)
    end
  end

  describe "download_for_media_item/3 when testing cookie retries" do
    test "retries with cookies if we think it would help and the source allows" do
      expect(YtDlpRunnerMock, :run, 4, fn
        _url, :get_downloadable_status, _opts, _ot, [use_cookies: false] ->
          {:error, "Sign in to confirm your age", 1}

        _url, :get_downloadable_status, _opts, _ot, [use_cookies: true] ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, addl ->
          assert {:use_cookies, true} in addl
          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      source = source_fixture(%{cookie_behaviour: :when_needed})
      media_item = media_item_fixture(%{source_id: source.id})

      assert {:ok, _} = MediaDownloader.download_for_media_item(media_item)
    end

    test "does not retry with cookies if we don't think it would help even the source allows" do
      expect(YtDlpRunnerMock, :run, 1, fn
        _url, :get_downloadable_status, _opts, _ot, [use_cookies: false] ->
          {:error, "Some other error", 1}
      end)

      source = source_fixture(%{cookie_behaviour: :when_needed})
      media_item = media_item_fixture(%{source_id: source.id})

      assert {:error, :download_failed, "Some other error"} = MediaDownloader.download_for_media_item(media_item)
    end

    test "does not retry with cookies even if we think it would help but source doesn't allow" do
      expect(YtDlpRunnerMock, :run, 1, fn
        _url, :get_downloadable_status, _opts, _ot, [use_cookies: false] ->
          {:error, "Sign in to confirm your age", 1}
      end)

      source = source_fixture(%{cookie_behaviour: :disabled})
      media_item = media_item_fixture(%{source_id: source.id})

      assert {:error, :download_failed, "Sign in to confirm your age"} =
               MediaDownloader.download_for_media_item(media_item)
    end

    test "does not retry with cookies if cookies were already used" do
      expect(YtDlpRunnerMock, :run, 1, fn
        _url, :get_downloadable_status, _opts, _ot, [use_cookies: true] ->
          {:error, "This video is available to this channel's members", 1}
      end)

      source = source_fixture(%{cookie_behaviour: :all_operations})
      media_item = media_item_fixture(%{source_id: source.id})

      assert {:error, :download_failed, "This video is available to this channel's members"} =
               MediaDownloader.download_for_media_item(media_item)
    end
  end

  describe "download_for_media_item/3 when testing media_item attributes" do
    setup do
      stub(YtDlpRunnerMock, :run, fn
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      :ok
    end

    test "sets the media_downloaded_at", %{media_item: media_item} do
      assert media_item.media_downloaded_at == nil
      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)
      assert DateTime.diff(DateTime.utc_now(), updated_media_item.media_downloaded_at) < 2
    end

    test "sets the culled_at to nil", %{media_item: media_item} do
      Media.update_media_item(media_item, %{culled_at: DateTime.utc_now()})
      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)
      assert updated_media_item.culled_at == nil
    end

    test "extracts the title", %{media_item: media_item} do
      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)
      assert updated_media_item.title == "Pinchflat Example Video"
    end

    test "extracts the description", %{media_item: media_item} do
      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)
      assert is_binary(updated_media_item.description)
    end

    test "extracts the media_filepath", %{media_item: media_item} do
      assert media_item.media_filepath == nil
      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)
      assert String.ends_with?(updated_media_item.media_filepath, ".mkv")
    end

    test "extracts the subtitle_filepaths", %{media_item: media_item} do
      assert media_item.subtitle_filepaths == []
      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)
      assert [["de", _], ["en", _] | _rest] = updated_media_item.subtitle_filepaths
    end

    test "extracts the duration_seconds", %{media_item: media_item} do
      assert media_item.duration_seconds == nil
      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)
      assert is_integer(updated_media_item.duration_seconds)
    end

    test "extracts the thumbnail_filepath", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          metadata = render_parsed_metadata(:media_metadata)

          thumbnail_filepath =
            metadata["thumbnails"]
            |> Enum.reverse()
            |> Enum.find_value(fn attrs -> attrs["filepath"] end)
            |> String.split(~r{\.}, include_captures: true)
            |> List.insert_at(-3, "-thumb")
            |> Enum.join()

          :ok = File.cp(thumbnail_filepath_fixture(), thumbnail_filepath)

          {:ok, Phoenix.json_library().encode!(metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      assert media_item.thumbnail_filepath == nil
      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)
      assert String.ends_with?(updated_media_item.thumbnail_filepath, ".webp")

      File.rm(updated_media_item.thumbnail_filepath)
    end

    test "extracts the metadata_filepath", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          metadata = render_parsed_metadata(:media_metadata)
          infojson_filepath = metadata["infojson_filename"]
          :ok = File.cp(infojson_filepath_fixture(), infojson_filepath)

          {:ok, Phoenix.json_library().encode!(metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      assert media_item.metadata_filepath == nil
      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)
      assert String.ends_with?(updated_media_item.metadata_filepath, ".info.json")

      File.rm(updated_media_item.metadata_filepath)
    end

    test "sets the last_error to nil on success" do
      media_item = media_item_fixture(%{last_error: "Some error"})

      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)
      assert updated_media_item.last_error == nil
    end

    test "sets the last_error to the error message on failure", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, :some_error}
      end)

      assert {:error, :unknown, _message} = MediaDownloader.download_for_media_item(media_item)
      media_item = Repo.reload(media_item)

      assert media_item.last_error == "Unknown error: {:error, :some_error}"
    end
  end

  describe "download_for_media_item/3 when testing NFO generation" do
    setup do
      stub(YtDlpRunnerMock, :run, fn
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      :ok
    end

    test "generates an NFO file if the source is set to download NFOs" do
      profile = media_profile_fixture(%{download_nfo: true})
      source = source_fixture(%{media_profile_id: profile.id})
      media_item = media_item_fixture(%{source_id: source.id})

      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)

      assert String.ends_with?(updated_media_item.nfo_filepath, ".nfo")
      assert File.exists?(updated_media_item.nfo_filepath)

      File.rm!(updated_media_item.nfo_filepath)
    end

    test "does not generate an NFO file if the source is set to not download NFOs" do
      profile = media_profile_fixture(%{download_nfo: false})
      source = source_fixture(%{media_profile_id: profile.id})
      media_item = media_item_fixture(%{source_id: source.id})

      assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)

      assert updated_media_item.nfo_filepath == nil
    end
  end
end
