defmodule Pinchflat.Metadata.SourceMetadataStorageWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Sources
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  describe "kickoff_with_task/1" do
    test "enqueues a new worker for the source" do
      source = source_fixture()

      assert {:ok, _} = SourceMetadataStorageWorker.kickoff_with_task(source)

      assert_enqueued(worker: SourceMetadataStorageWorker, args: %{"id" => source.id})
    end

    test "creates a new task for the source" do
      source = source_fixture()

      assert {:ok, task} = SourceMetadataStorageWorker.kickoff_with_task(source)

      assert task.source_id == source.id
    end
  end

  describe "perform/1" do
    test "won't call itself in an infinite loop" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, "{}"}
      end)

      source = source_fixture()

      perform_job(SourceMetadataStorageWorker, %{id: source.id})

      assert [] = all_enqueued(worker: SourceMetadataStorageWorker)
    end

    test "does not blow up if the record doesn't exist" do
      assert :ok = perform_job(SourceMetadataStorageWorker, %{id: 0})
    end
  end

  describe "perform/1 when testing attribute updates" do
    test "the source description is saved" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, render_metadata(:channel_source_metadata)}
      end)

      source = source_fixture(%{description: nil})

      refute source.description
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)

      assert source.description == "This is a test file for Pinchflat"
    end
  end

  describe "perform/1 when testing metadata storage" do
    test "sets metadata location for source" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, "{}"}
      end)

      source = Repo.preload(source_fixture(), :metadata)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)

      assert source.metadata.metadata_filepath

      File.rm!(source.metadata.metadata_filepath)
    end

    test "fetches and stores returned metadata for source" do
      source = source_fixture()
      file_contents = Phoenix.json_library().encode!(%{"title" => "test"})

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, file_contents}
      end)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)
      {:ok, metadata} = MetadataFileHelpers.read_compressed_metadata(source.metadata.metadata_filepath)

      assert metadata == %{"title" => "test"}
    end

    test "sets metadata image location for source" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, render_metadata(:channel_source_metadata)}
      end)

      source = source_fixture()

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)

      assert source.metadata.fanart_filepath
      assert source.metadata.poster_filepath
      assert source.metadata.banner_filepath

      Sources.delete_source(source, delete_files: true)
    end

    test "stores metadata images for source" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, render_metadata(:channel_source_metadata)}
      end)

      source = source_fixture()

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)

      assert File.exists?(source.metadata.fanart_filepath)
      assert File.exists?(source.metadata.poster_filepath)
      assert File.exists?(source.metadata.banner_filepath)

      Sources.delete_source(source, delete_files: true)
    end
  end

  describe "perform/1 when testing source image downloading" do
    test "downloads and stores source images" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "show", "Season 1", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, opts, _ot, _addl ->
          assert {:convert_thumbnails, "jpg"} in opts

          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      assert source.fanart_filepath
      assert source.poster_filepath
      assert source.banner_filepath

      assert File.exists?(source.fanart_filepath)
      assert File.exists?(source.poster_filepath)
      assert File.exists?(source.banner_filepath)

      Sources.delete_source(source, delete_files: true)
    end

    test "calls one set of yt-dlp metadata opts for channels" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, opts, _ot, _addl ->
          assert {:playlist_items, 0} in opts
          assert :write_all_thumbnails in opts

          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id, collection_type: :channel)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "calls another set of yt-dlp metadata opts for playlists" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, opts, _ot, _addl ->
          assert {:playlist_items, 1} in opts
          assert :write_thumbnail in opts

          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id, collection_type: :playlist)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "does not store source images if the profile is not set to" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "show", "Season 1", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: false})
      source = source_fixture(media_profile_id: profile.id)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      refute source.fanart_filepath
      refute source.poster_filepath
      refute source.banner_filepath
    end

    test "does not store source images if the series directory cannot be determined" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "foo", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      refute source.fanart_filepath
      refute source.poster_filepath
      refute source.banner_filepath
    end

    test "sets use_cookies if the source uses cookies" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, addl ->
          assert {:use_cookies, true} in addl
          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id, cookie_behaviour: :all_operations)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "does not set use_cookies if the source uses cookies when needed" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id, cookie_behaviour: :when_needed)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "does not set use_cookies if the source does not use cookies" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id, cookie_behaviour: :disabled)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end
  end

  describe "perform/1 when cleaning up the downloaded source images" do
    test "deletes the temporary directory the images are downloaded to once they're stored" do
      test_pid = self()

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, opts, _ot, _addl ->
          tmp_image_directory = Path.dirname(Keyword.fetch!(opts, :output))
          send(test_pid, {:tmp_image_directory, tmp_image_directory})

          {:ok, download_source_images_to(tmp_image_directory)}
      end)

      source = source_fixture()

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)

      assert_received {:tmp_image_directory, tmp_image_directory}
      refute File.exists?(tmp_image_directory)
      assert File.exists?(source.metadata.poster_filepath)

      Sources.delete_source(source, delete_files: true)
    end

    test "deletes the temporary directory the images are downloaded to if fetching the metadata fails" do
      test_pid = self()

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, opts, _ot, _addl ->
          tmp_image_directory = Path.dirname(Keyword.fetch!(opts, :output))
          send(test_pid, {:tmp_image_directory, tmp_image_directory})
          FilesystemUtils.write_p!(Path.join(tmp_image_directory, "source_image.jpg"), "partial image")

          {:error, "Unable to download the images", 1}
      end)

      source = source_fixture()

      assert_raise MatchError, fn -> perform_job(SourceMetadataStorageWorker, %{id: source.id}) end

      assert_received {:tmp_image_directory, tmp_image_directory}
      refute File.exists?(tmp_image_directory)
    end
  end

  describe "perform/1 when determining the series_directory" do
    test "sets the series directory based on the returned media filepath" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "show", "Season 1", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      source = source_fixture(%{series_directory: nil})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      assert source.series_directory
    end

    test "does not set the series directory if it cannot be determined" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "foo", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      source = source_fixture(%{series_directory: nil})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      refute source.series_directory
    end

    test "sets use_cookies if the source is set to use cookies" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, addl ->
          assert {:use_cookies, true} in addl
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      source = source_fixture(%{series_directory: nil, cookie_behaviour: :all_operations})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "does not set use_cookies if the source uses cookies when needed" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      source = source_fixture(%{series_directory: nil, cookie_behaviour: :when_needed})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "does not set use_cookies if the source is not set to use cookies" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      source = source_fixture(%{series_directory: nil, cookie_behaviour: :disabled})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end
  end

  describe "perform/1 when storing the series NFO" do
    test "stores the NFO if specified" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "show", "Season 1", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      profile = media_profile_fixture(%{download_nfo: true})
      source = source_fixture(%{nfo_filepath: nil, media_profile_id: profile.id})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      assert source.nfo_filepath
      assert source.nfo_filepath == Path.join([source.series_directory, "tvshow.nfo"])
      assert File.exists?(source.nfo_filepath)

      File.rm!(source.nfo_filepath)
    end

    test "does not store the NFO if not specified" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "show", "Season 1", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      profile = media_profile_fixture(%{download_nfo: false})
      source = source_fixture(%{nfo_filepath: nil, media_profile_id: profile.id})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      refute source.nfo_filepath
    end

    test "does not store the NFO if the series directory cannot be determined" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "foo", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      profile = media_profile_fixture(%{download_nfo: true})
      source = source_fixture(%{nfo_filepath: nil, media_profile_id: profile.id})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      refute source.nfo_filepath
    end
  end

  describe "perform/1 when the source's stored files are replaced" do
    setup do
      media_directory = Application.get_env(:pinchflat, :media_directory)
      suffix = :rand.uniform(1_000_000)

      %{
        series_directory: Path.join(media_directory, "show #{suffix}"),
        new_series_directory: Path.join(media_directory, "new show #{suffix}")
      }
    end

    test "deletes the stored NFO once the profile stops downloading NFOs", %{series_directory: series_directory} do
      stub_source_lookups(series_directory, "{}")
      nfo_filepath = Path.join(series_directory, "tvshow.nfo")
      FilesystemUtils.write_p!(nfo_filepath, "old NFO")

      profile = media_profile_fixture(%{download_nfo: false})

      source =
        source_fixture(%{media_profile_id: profile.id, series_directory: series_directory, nfo_filepath: nfo_filepath})

      perform_job(SourceMetadataStorageWorker, %{id: source.id})

      refute Repo.reload(source).nfo_filepath
      refute File.exists?(nfo_filepath)
    end

    test "deletes the old series directory's NFO and images when the series directory changes", context do
      stub_source_lookups(context.new_series_directory, render_metadata(:channel_source_metadata))

      old_filepaths = %{
        nfo_filepath: Path.join(context.series_directory, "tvshow.nfo"),
        poster_filepath: Path.join(context.series_directory, "poster.jpg"),
        fanart_filepath: Path.join(context.series_directory, "fanart.jpg"),
        banner_filepath: Path.join(context.series_directory, "banner.jpg")
      }

      Enum.each(old_filepaths, fn {_field, filepath} -> FilesystemUtils.write_p!(filepath, "old file") end)

      profile = media_profile_fixture(%{download_nfo: true, download_source_images: true})
      source_attrs = %{media_profile_id: profile.id, series_directory: context.series_directory}
      source = source_fixture(Map.merge(source_attrs, old_filepaths))
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)

      assert source.series_directory == context.new_series_directory

      for {field, old_filepath} <- old_filepaths do
        new_filepath = Map.fetch!(source, field)

        assert Path.dirname(new_filepath) == context.new_series_directory
        assert File.exists?(new_filepath)
        refute File.exists?(old_filepath)
      end

      # The source's images in the internal metadata directory are left alone
      assert File.exists?(source.metadata.poster_filepath)
      assert File.exists?(source.metadata.fanart_filepath)
      assert File.exists?(source.metadata.banner_filepath)

      Sources.delete_source(source, delete_files: true)
    end

    test "keeps the stored NFO when its path doesn't change", %{series_directory: series_directory} do
      stub_source_lookups(series_directory, "{}")
      nfo_filepath = Path.join(series_directory, "tvshow.nfo")
      FilesystemUtils.write_p!(nfo_filepath, "old NFO")

      profile = media_profile_fixture(%{download_nfo: true})

      source =
        source_fixture(%{media_profile_id: profile.id, series_directory: series_directory, nfo_filepath: nfo_filepath})

      perform_job(SourceMetadataStorageWorker, %{id: source.id})

      assert Repo.reload(source).nfo_filepath == nfo_filepath
      assert File.exists?(nfo_filepath)

      File.rm!(nfo_filepath)
    end

    test "doesn't delete a stored NFO that's outside the media directory", %{series_directory: series_directory} do
      stub_source_lookups(series_directory, "{}")
      outside_nfo_filepath = FilesystemUtils.generate_metadata_tmpfile(:nfo)

      profile = media_profile_fixture(%{download_nfo: false})

      source =
        source_fixture(%{
          media_profile_id: profile.id,
          series_directory: series_directory,
          nfo_filepath: outside_nfo_filepath
        })

      perform_job(SourceMetadataStorageWorker, %{id: source.id})

      refute Repo.reload(source).nfo_filepath
      assert File.exists?(outside_nfo_filepath)

      File.rm!(outside_nfo_filepath)
    end

    # Sources for the same channel (e.g. with different title filters) can share a series directory
    test "doesn't delete a stored NFO that another source still uses", %{series_directory: series_directory} do
      stub_source_lookups(series_directory, "{}")
      nfo_filepath = Path.join(series_directory, "tvshow.nfo")
      FilesystemUtils.write_p!(nfo_filepath, "shared NFO")

      _other_source = source_fixture(%{series_directory: series_directory, nfo_filepath: nfo_filepath})
      profile = media_profile_fixture(%{download_nfo: false})

      source =
        source_fixture(%{media_profile_id: profile.id, series_directory: series_directory, nfo_filepath: nfo_filepath})

      perform_job(SourceMetadataStorageWorker, %{id: source.id})

      refute Repo.reload(source).nfo_filepath
      assert File.exists?(nfo_filepath)

      File.rm!(nfo_filepath)
    end
  end

  defp stub_source_lookups(series_directory, source_metadata) do
    stub(YtDlpRunnerMock, :run, fn
      _url, :get_source_details, _opts, _ot, _addl ->
        filename = Path.join([series_directory, "Season 1", "bar.mp4"])

        {:ok, source_details_return_fixture(%{filename: filename})}

      _url, :get_source_metadata, _opts, _ot, _addl ->
        {:ok, source_metadata}
    end)
  end

  # Does what yt-dlp does: downloads the source's images to the directory and returns the
  # source's metadata, which includes where each image is
  defp download_source_images_to(directory) do
    metadata = render_parsed_metadata(:channel_source_metadata)

    thumbnails =
      Enum.map(metadata["thumbnails"], fn
        %{"filepath" => filepath} = thumbnail when is_binary(filepath) ->
          downloaded_filepath = Path.join(directory, Path.basename(filepath))
          FilesystemUtils.cp_p!(filepath, downloaded_filepath)

          Map.put(thumbnail, "filepath", downloaded_filepath)

        thumbnail ->
          thumbnail
      end)

    Phoenix.json_library().encode!(Map.put(metadata, "thumbnails", thumbnails))
  end
end
