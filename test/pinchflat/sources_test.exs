defmodule Pinchflat.SourcesTest do
  use Pinchflat.DataCase

  import Pinchflat.TasksFixtures
  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.FastIndexing.FastIndexingWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker

  @invalid_source_attrs %{name: nil, collection_id: nil}

  describe "schema" do
    test "source_metadata is deleted when the source is deleted" do
      source =
        source_fixture(%{metadata: %{metadata_filepath: "/metadata.json.gz"}})

      metadata = source.metadata
      assert {:ok, %Source{}} = Sources.delete_source(source)

      assert_raise Ecto.NoResultsError, fn ->
        Repo.reload!(metadata)
      end
    end

    test "can be JSON encoded without error" do
      source = source_fixture()

      assert {:ok, _} = Phoenix.json_library().encode(source)
    end
  end

  describe "output_path_template/1" do
    test "returns the source's override if present" do
      source = source_fixture(%{output_path_template_override: "/override/{{ title }}.{{ ext }}"})

      assert Sources.output_path_template(source) == "/override/{{ title }}.{{ ext }}"
    end

    test "returns the media profile's template if no override is present" do
      media_profile = media_profile_fixture(%{output_path_template: "/profile/{{ title }}.{{ ext }}"})
      source = source_fixture(%{media_profile_id: media_profile.id})

      assert Sources.output_path_template(source) == "/profile/{{ title }}.{{ ext }}"
    end

    test "Treats empty strings as being blank" do
      media_profile = media_profile_fixture(%{output_path_template: "/profile/{{ title }}.{{ ext }}"})
      source = source_fixture(%{media_profile_id: media_profile.id, output_path_template_override: "  "})

      assert Sources.output_path_template(source) == "/profile/{{ title }}.{{ ext }}"
    end
  end

  describe "use_cookies?/2" do
    test "returns true if the source has been set to use cookies" do
      source = source_fixture(%{cookie_behaviour: :all_operations})
      assert Sources.use_cookies?(source, :downloading)
    end

    test "returns false if the source has not been set to use cookies" do
      source = source_fixture(%{cookie_behaviour: :disabled})
      refute Sources.use_cookies?(source, :downloading)
    end

    test "returns true if the action is indexing and the source is set to :when_needed" do
      source = source_fixture(%{cookie_behaviour: :when_needed})
      assert Sources.use_cookies?(source, :indexing)
    end

    test "returns false if the action is downloading and the source is set to :when_needed" do
      source = source_fixture(%{cookie_behaviour: :when_needed})
      refute Sources.use_cookies?(source, :downloading)
    end

    test "returns true if the action is error_recovery and the source is set to :when_needed" do
      source = source_fixture(%{cookie_behaviour: :when_needed})
      assert Sources.use_cookies?(source, :error_recovery)
    end
  end

  describe "list_sources/0" do
    test "it returns all sources" do
      source = source_fixture()
      assert Sources.list_sources() == [source]
    end
  end

  describe "list_sources_for/1" do
    test "returns all sources for a given media profile" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)

      assert Sources.list_sources_for(media_profile) == [source]
    end
  end

  describe "get_source!/1" do
    test "it returns the source with given id" do
      source = source_fixture()
      assert Sources.get_source!(source.id) == source
    end
  end

  describe "create_source/2" do
    test "automatically sets the UUID" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123"
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)
      assert String.length(source.uuid) == 36
    end

    test "UUID is not writable by the user" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        uuid: "some_uuid"
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)
      assert String.length(source.uuid) == 36
    end

    test "creates a source and adds name + ID from runner response for channels" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123"
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)
      assert source.collection_name == "some channel name"
      assert String.starts_with?(source.collection_id, "some_channel_id_")
    end

    test "creates a source and adds name + ID for playlists" do
      expect(YtDlpRunnerMock, :run, &playlist_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/playlist?list=abc123"
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)
      assert source.collection_name == "some playlist name"
      assert String.starts_with?(source.collection_id, "some_playlist_id_")
    end

    test "adds an error if the runner fails" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl -> {:error, "some error", 1} end)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123"
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Sources.create_source(valid_attrs)
      assert "could not fetch source details from URL" in errors_on(changeset).original_url
    end

    test "adds an error if the runner succeeds but the result was invalid JSON" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl -> {:ok, "Not JSON"} end)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123"
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Sources.create_source(valid_attrs)
      assert "could not fetch source details from URL" in errors_on(changeset).original_url
    end

    test "you can specify a custom custom_name" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        custom_name: "some custom name"
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)

      assert source.custom_name == "some custom name"
    end

    test "friendly name is pulled from collection_name if not specified" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123"
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)

      assert source.custom_name == "some channel name"
    end

    test "creation enforces uniqueness of collection_id scoped to the media_profile and title regex" do
      expect(YtDlpRunnerMock, :run, 2, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "some channel name",
           channel_id: "some_channel_id_12345678",
           playlist_id: "some_channel_id_12345678",
           playlist_title: "some channel name - videos"
         })}
      end)

      valid_once_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        title_filter_regex: nil
      }

      assert {:ok, %Source{}} = Sources.create_source(valid_once_attrs)
      assert {:error, %Ecto.Changeset{}} = Sources.create_source(valid_once_attrs)
    end

    test "creation lets you duplicate collection_ids and profiles as long as the regex is different" do
      expect(YtDlpRunnerMock, :run, 2, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "some channel name",
           channel_id: "some_channel_id_12345678",
           playlist_id: "some_channel_id_12345678",
           playlist_title: "some channel name - videos"
         })}
      end)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        name: "some name",
        original_url: "https://www.youtube.com/channel/abc123"
      }

      source_1_attrs = Map.merge(valid_attrs, %{title_filter_regex: "foo"})
      source_2_attrs = Map.merge(valid_attrs, %{title_filter_regex: "bar"})

      assert {:ok, %Source{}} = Sources.create_source(source_1_attrs)
      assert {:ok, %Source{}} = Sources.create_source(source_2_attrs)
    end

    test "creation lets you duplicate collection_ids as long as the media profile is different" do
      expect(YtDlpRunnerMock, :run, 2, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "some channel name",
           channel_id: "some_channel_id_12345678",
           playlist_id: "some_channel_id_12345678",
           playlist_title: "some channel name - videos"
         })}
      end)

      valid_attrs = %{
        name: "some name",
        original_url: "https://www.youtube.com/channel/abc123",
        title_filter_regex: "TEST"
      }

      source_1_attrs = Map.merge(valid_attrs, %{media_profile_id: media_profile_fixture().id})
      source_2_attrs = Map.merge(valid_attrs, %{media_profile_id: media_profile_fixture().id})

      assert {:ok, %Source{}} = Sources.create_source(source_1_attrs)
      assert {:ok, %Source{}} = Sources.create_source(source_2_attrs)
    end

    test "collection_type is inferred from source details" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)
      expect(YtDlpRunnerMock, :run, &playlist_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123"
      }

      assert {:ok, %Source{} = source_1} = Sources.create_source(valid_attrs)
      assert {:ok, %Source{} = source_2} = Sources.create_source(valid_attrs)

      assert source_1.collection_type == :channel
      assert source_2.collection_type == :playlist
    end

    test "creation with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Sources.create_source(@invalid_source_attrs)
    end

    test "creation with invalid data fails fast and does not call the runner" do
      expect(YtDlpRunnerMock, :run, 0, &channel_mock/5)

      assert {:error, %Ecto.Changeset{}} = Sources.create_source(@invalid_source_attrs)
    end

    test "creation will schedule the indexing task" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123"
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)

      assert_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
    end

    test "creation will schedule a fast indexing job if the fast_index option is set" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        fast_index: true
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)

      assert_enqueued(worker: FastIndexingWorker, args: %{"id" => source.id})
    end

    test "creation will not schedule a fast indexing job if the fast_index option is not set" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        fast_index: false
      }

      assert {:ok, %Source{}} = Sources.create_source(valid_attrs)

      refute_enqueued(worker: FastIndexingWorker)
    end

    test "creation schedules an index test even if the index frequency is 0" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        index_frequency_minutes: 0
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)

      assert_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
    end

    test "fast_index forces the index frequency to be a default value" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        fast_index: true,
        index_frequency_minutes: 0
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)

      assert source.index_frequency_minutes == Source.index_frequency_when_fast_indexing()
    end

    test "disabling fast index will not change the index frequency" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        fast_index: false,
        index_frequency_minutes: 0
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)

      assert source.index_frequency_minutes == 0
    end

    test "creating will kickoff a metadata storage worker" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        fast_index: false,
        index_frequency_minutes: 0
      }

      assert {:ok, %Source{} = source} = Sources.create_source(valid_attrs)

      assert_enqueued(worker: SourceMetadataStorageWorker, args: %{"id" => source.id})
    end
  end

  describe "create_source/2 when testing yt-dlp options" do
    test "sets use_cookies to true if the source has been set to use cookies" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, addl ->
        assert Keyword.get(addl, :use_cookies)

        {:ok, playlist_return()}
      end)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        cookie_behaviour: :all_operations
      }

      assert {:ok, %Source{}} = Sources.create_source(valid_attrs)
    end

    test "does not set use_cookies if the source uses cookies when needed" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, addl ->
        refute Keyword.get(addl, :use_cookies)

        {:ok, playlist_return()}
      end)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        cookie_behaviour: :when_needed
      }

      assert {:ok, %Source{}} = Sources.create_source(valid_attrs)
    end

    test "does not set use_cookies if the source has not been set to use cookies" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, addl ->
        refute Keyword.get(addl, :use_cookies)

        {:ok, playlist_return()}
      end)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123",
        cookie_behaviour: :disabled
      }

      assert {:ok, %Source{}} = Sources.create_source(valid_attrs)
    end

    test "skips sleep interval" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, addl ->
        assert Keyword.get(addl, :skip_sleep_interval)

        {:ok, playlist_return()}
      end)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123"
      }

      assert {:ok, %Source{}} = Sources.create_source(valid_attrs)
    end
  end

  describe "create_source/2 when testing its options" do
    test "run_post_commit_tasks: false won't enqueue post-commit tasks" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      valid_attrs = %{
        media_profile_id: media_profile_fixture().id,
        original_url: "https://www.youtube.com/channel/abc123"
      }

      assert {:ok, %Source{}} = Sources.create_source(valid_attrs, run_post_commit_tasks: false)

      refute_enqueued(worker: MediaCollectionIndexingWorker)
      refute_enqueued(worker: SourceMetadataStorageWorker)
    end
  end

  describe "update_source/3" do
    test "updates with valid data updates the source" do
      source = source_fixture()
      update_attrs = %{collection_name: "some updated name"}

      assert {:ok, %Source{} = source} = Sources.update_source(source, update_attrs)
      assert source.collection_name == "some updated name"
    end

    test "updates with invalid data fails fast and does not call the runner" do
      expect(YtDlpRunnerMock, :run, 0, &channel_mock/5)

      source = source_fixture()

      assert {:error, %Ecto.Changeset{}} = Sources.update_source(source, @invalid_source_attrs)
    end

    test "updating the original_url will re-fetch the source details for channels" do
      expect(YtDlpRunnerMock, :run, &channel_mock/5)

      source = source_fixture()
      update_attrs = %{original_url: "https://www.youtube.com/channel/abc123"}

      assert {:ok, %Source{} = source} = Sources.update_source(source, update_attrs)
      assert source.collection_name == "some channel name"
      assert String.starts_with?(source.collection_id, "some_channel_id_")
    end

    test "updating the original_url will re-fetch the source details for playlists" do
      expect(YtDlpRunnerMock, :run, &playlist_mock/5)

      source = source_fixture()
      update_attrs = %{original_url: "https://www.youtube.com/playlist?list=abc123"}

      assert {:ok, %Source{} = source} = Sources.update_source(source, update_attrs)
      assert source.collection_name == "some playlist name"
      assert String.starts_with?(source.collection_id, "some_playlist_id_")
    end

    test "not updating the original_url will not re-fetch the source details" do
      expect(YtDlpRunnerMock, :run, 0, &channel_mock/5)

      source = source_fixture()
      update_attrs = %{name: "some updated name"}

      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
    end

    test "updates with invalid data returns error changeset" do
      source = source_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Sources.update_source(source, @invalid_source_attrs)

      assert source == Sources.get_source!(source.id)
    end

    test "updating will kickoff a metadata storage worker if the original_url changes" do
      expect(YtDlpRunnerMock, :run, &playlist_mock/5)
      source = source_fixture()
      update_attrs = %{original_url: "https://www.youtube.com/channel/cba321"}

      assert {:ok, %Source{} = source} = Sources.update_source(source, update_attrs)

      assert_enqueued(worker: SourceMetadataStorageWorker, args: %{"id" => source.id})
    end

    test "updating will not kickoff a metadata storage worker other attrs change" do
      source = source_fixture()
      update_attrs = %{name: "some new name"}

      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)

      refute_enqueued(worker: SourceMetadataStorageWorker)
    end
  end

  describe "update_source/3 when testing media download tasks" do
    test "enabling the download_media attribute will schedule a download task" do
      source = source_fixture(download_media: false)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      update_attrs = %{download_media: true}

      refute_enqueued(worker: MediaDownloadWorker)
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "disabling the download_media attribute will cancel the download task" do
      source = source_fixture(download_media: true, enabled: true)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      update_attrs = %{download_media: false}
      DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "enabling download_media will not schedule a task if the source is disabled" do
      source = source_fixture(download_media: false, enabled: false)
      _media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      update_attrs = %{download_media: true}

      refute_enqueued(worker: MediaDownloadWorker)
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "disabling a source will cancel any pending download tasks" do
      source = source_fixture(download_media: true, enabled: true)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      update_attrs = %{enabled: false}
      DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "enabling a source will schedule a download task if download_media is true" do
      source = source_fixture(download_media: true, enabled: false)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      update_attrs = %{enabled: true}

      refute_enqueued(worker: MediaDownloadWorker)
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "enabling a source will not schedule a download task if download_media is false" do
      source = source_fixture(download_media: false, enabled: false)
      _media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      update_attrs = %{enabled: true}

      refute_enqueued(worker: MediaDownloadWorker)
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      refute_enqueued(worker: MediaDownloadWorker)
    end
  end

  describe "update_source/3 when testing slow indexing" do
    test "updating the index frequency to >0 will re-schedule the indexing task" do
      source = source_fixture()
      update_attrs = %{index_frequency_minutes: 123}

      assert {:ok, %Source{} = source} = Sources.update_source(source, update_attrs)
      assert source.index_frequency_minutes == 123
      assert_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
    end

    test "updating the index frequency to 0 will not re-schedule the indexing task" do
      source = source_fixture()
      update_attrs = %{index_frequency_minutes: 0}

      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)

      refute_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
    end

    test "updating the index frequency to 0 will delete any pending tasks" do
      source = source_fixture()
      update_attrs = %{index_frequency_minutes: 0}

      {:ok, job_1} = Oban.insert(FastIndexingWorker.new(%{"id" => source.id}))
      task_1 = task_fixture(source_id: source.id, job_id: job_1.id)
      {:ok, job_2} = Oban.insert(MediaCollectionIndexingWorker.new(%{"id" => source.id}))
      task_2 = task_fixture(source_id: source.id, job_id: job_2.id)

      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(task_1) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(task_2) end
    end

    test "not updating the index frequency will not re-schedule the indexing task or delete tasks" do
      source = source_fixture()
      task = task_fixture(source_id: source.id)
      update_attrs = %{name: "some updated name"}

      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)

      assert Repo.reload!(task)
      refute_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
    end

    test "disabling a source will delete any pending tasks" do
      source = source_fixture()
      update_attrs = %{enabled: false}

      {:ok, job} = Oban.insert(MediaCollectionIndexingWorker.new(%{"id" => source.id}))
      task = task_fixture(source_id: source.id, job_id: job.id)

      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(task) end
    end

    test "updating the index frequency will not create a task if the source is disabled" do
      source = source_fixture(enabled: false)
      update_attrs = %{index_frequency_minutes: 123}

      refute_enqueued(worker: MediaCollectionIndexingWorker)
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      refute_enqueued(worker: MediaCollectionIndexingWorker)
    end

    test "enabling a source will create a task if the index frequency is >0" do
      source = source_fixture(enabled: false, index_frequency_minutes: 123)
      update_attrs = %{enabled: true}

      refute_enqueued(worker: MediaCollectionIndexingWorker)
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      assert_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
    end

    test "enabling a source will not create a task if the index frequency is 0" do
      source = source_fixture(enabled: false, index_frequency_minutes: 0)
      update_attrs = %{enabled: true}

      refute_enqueued(worker: MediaCollectionIndexingWorker)
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      refute_enqueued(worker: MediaCollectionIndexingWorker)
    end
  end

  describe "update_source/3 when testing fast indexing" do
    test "enabling fast_index will schedule a fast indexing task" do
      source = source_fixture(fast_index: false)
      update_attrs = %{fast_index: true}

      refute_enqueued(worker: FastIndexingWorker)
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      assert_enqueued(worker: FastIndexingWorker, args: %{"id" => source.id})
    end

    test "disabling fast_index will cancel the fast indexing task" do
      source = source_fixture(fast_index: true)
      update_attrs = %{fast_index: false}
      {:ok, job} = Oban.insert(FastIndexingWorker.new(%{"id" => source.id}))
      task_fixture(source_id: source.id, job_id: job.id)

      assert_enqueued(worker: FastIndexingWorker, args: %{"id" => source.id})
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      refute_enqueued(worker: FastIndexingWorker)
    end

    test "fast_index forces the index frequency to be a default value" do
      source = source_fixture(%{fast_index: true})
      update_attrs = %{index_frequency_minutes: 0}

      assert {:ok, source} = Sources.update_source(source, update_attrs)

      assert source.index_frequency_minutes == Source.index_frequency_when_fast_indexing()
    end

    test "disabling fast index will not change the index frequency" do
      source = source_fixture(%{fast_index: false})
      update_attrs = %{index_frequency_minutes: 0}

      assert {:ok, source} = Sources.update_source(source, update_attrs)

      assert source.index_frequency_minutes == 0
    end

    test "disabling a source will delete any pending tasks" do
      source = source_fixture()
      update_attrs = %{enabled: false}

      {:ok, job} = Oban.insert(FastIndexingWorker.new(%{"id" => source.id}))
      task = task_fixture(source_id: source.id, job_id: job.id)

      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(task) end
    end

    test "updating fast indexing will not create a task if the source is disabled" do
      source = source_fixture(enabled: false, fast_index: false)
      update_attrs = %{fast_index: true}

      refute_enqueued(worker: FastIndexingWorker)
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      refute_enqueued(worker: FastIndexingWorker)
    end

    test "enabling a source will create a task if fast_index is true" do
      source = source_fixture(enabled: false, fast_index: true)
      update_attrs = %{enabled: true}

      refute_enqueued(worker: FastIndexingWorker)
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      assert_enqueued(worker: FastIndexingWorker, args: %{"id" => source.id})
    end

    test "enabling a source will not create a task if fast_index is false" do
      source = source_fixture(enabled: false, fast_index: false)
      update_attrs = %{enabled: true}

      refute_enqueued(worker: FastIndexingWorker)
      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs)
      refute_enqueued(worker: FastIndexingWorker)
    end
  end

  describe "update_source/3 when testing options" do
    test "run_post_commit_tasks: false won't enqueue post-commit tasks" do
      source = source_fixture(%{fast_index: false, download_media: false, index_frequency_minutes: -1})
      update_attrs = %{fast_index: true, download_media: true, index_frequency_minutes: 100}

      assert {:ok, %Source{}} = Sources.update_source(source, update_attrs, run_post_commit_tasks: false)

      refute_enqueued(worker: MediaCollectionIndexingWorker)
      refute_enqueued(worker: SourceMetadataStorageWorker)
      refute_enqueued(worker: MediaDownloadWorker)
      refute_enqueued(worker: FastIndexingWorker)
    end
  end

  describe "delete_source/2" do
    test "it deletes the source" do
      source = source_fixture()
      assert {:ok, %Source{}} = Sources.delete_source(source)
      assert_raise Ecto.NoResultsError, fn -> Sources.get_source!(source.id) end
    end

    test "it returns a source changeset" do
      source = source_fixture()
      assert %Ecto.Changeset{} = Sources.change_source(source)
    end

    test "deletion also deletes all associated tasks" do
      source = source_fixture()
      task = task_fixture(source_id: source.id)

      assert {:ok, %Source{}} = Sources.delete_source(source)
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(task) end
    end

    test "deletion also deletes all associated media items" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id)

      assert {:ok, %Source{}} = Sources.delete_source(source)
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_item) end
    end

    test "deletion does not delete media files by default" do
      source = source_fixture()
      media_item = media_item_with_attachments(%{source_id: source.id})

      assert {:ok, %Source{}} = Sources.delete_source(source)
      assert File.exists?(media_item.media_filepath)
    end

    test "deletes the source's metadata files" do
      stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)
      source = Repo.preload(source_fixture(), :metadata)

      update_attrs = %{
        metadata: %{
          metadata_filepath: MetadataFileHelpers.compress_and_store_metadata_for(source, %{})
        }
      }

      {:ok, updated_source} = Sources.update_source(source, update_attrs)

      assert {:ok, _} = Sources.delete_source(updated_source)
      refute File.exists?(updated_source.metadata.metadata_filepath)
    end

    test "does not delete the source's non-metadata files" do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:nfo)
      source = source_fixture(%{nfo_filepath: filepath})

      assert {:ok, _} = Sources.delete_source(source)
      assert File.exists?(filepath)

      File.rm!(filepath)
    end
  end

  describe "delete_source/2 when deleting files" do
    setup do
      stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

      :ok
    end

    test "deletes source and media_items" do
      source = source_fixture()
      media_item = media_item_with_attachments(%{source_id: source.id})

      assert {:ok, %Source{}} = Sources.delete_source(source, delete_files: true)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_item) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(source) end
    end

    test "also deletes media files" do
      source = source_fixture()
      media_item = media_item_with_attachments(%{source_id: source.id})

      assert {:ok, %Source{}} = Sources.delete_source(source, delete_files: true)

      refute File.exists?(media_item.media_filepath)
    end

    test "deletes the source's non-metadata files" do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:nfo)
      source = source_fixture(%{nfo_filepath: filepath})

      assert {:ok, _} = Sources.delete_source(source, delete_files: true)

      refute File.exists?(filepath)
    end
  end

  describe "change_source/3" do
    test "it returns a changeset" do
      source = source_fixture()

      assert %Ecto.Changeset{} = Sources.change_source(source)
    end
  end

  describe "change_source/3 when testing regex validation" do
    test "succeeds when a valid regex is provided" do
      source = source_fixture()

      assert %{errors: []} = Sources.change_source(source, %{title_filter_regex: "(?i)^How to Bike$"})
    end

    test "succeeds when a regex is set back to nil" do
      source = source_fixture(%{title_filter_regex: "(?i)^How to Bike$"})

      assert %{errors: []} = Sources.change_source(source, %{title_filter_regex: nil})
    end

    test "fails when an invalid regex is provided" do
      source = source_fixture()

      changeset = Sources.change_source(source, %{title_filter_regex: "*FOO"})

      assert "is invalid" in errors_on(changeset).title_filter_regex
    end
  end

  describe "change_source/3 when testing min/max duration validations" do
    test "succeeds if min and max are nil" do
      source = source_fixture()

      assert %{errors: []} = Sources.change_source(source, %{min_duration_seconds: nil, max_duration_seconds: nil})
    end

    test "succeeds if either min or max is nil" do
      source = source_fixture()

      assert %{errors: []} = Sources.change_source(source, %{min_duration_seconds: nil, max_duration_seconds: 100})
      assert %{errors: []} = Sources.change_source(source, %{min_duration_seconds: 100, max_duration_seconds: nil})
    end

    test "succeeds if min is less than max" do
      source = source_fixture()

      assert %{errors: []} = Sources.change_source(source, %{min_duration_seconds: 100, max_duration_seconds: 200})
    end

    test "fails if min is greater than or equal to max" do
      source = source_fixture()

      assert %{errors: [_]} = Sources.change_source(source, %{min_duration_seconds: 200, max_duration_seconds: 100})
      assert %{errors: [_]} = Sources.change_source(source, %{min_duration_seconds: 100, max_duration_seconds: 100})
    end
  end

  describe "update_source_directory/1" do
    test "updates source directory structure and moves files when custom_name changes" do
      # Setup: Create a source with old custom_name and files
      suffix = :rand.uniform(1_000_000)
      old_custom_name = "Old Name #{suffix}"
      new_custom_name = "New Name #{suffix}"
      shows_dir = Path.join(Application.get_env(:pinchflat, :media_directory), "shows")
      old_dir = Path.join(shows_dir, old_custom_name)
      new_dir = Path.join(shows_dir, new_custom_name)

      media_profile =
        media_profile_fixture(%{
          output_path_template:
            "shows/{{ source_custom_name }}/Season %(upload_date>%Y)S/s%(upload_date>%Y)Se%(upload_date>%m%d)S00 - %(title)S.%(ext)S",
          download_source_images: true,
          download_nfo: true
        })

      source =
        source_fixture(%{
          custom_name: old_custom_name,
          media_profile_id: media_profile.id,
          series_directory: old_dir,
          nfo_filepath: Path.join(old_dir, "tvshow.nfo"),
          poster_filepath: Path.join(old_dir, "poster.jpg"),
          fanart_filepath: Path.join(old_dir, "fanart.jpg")
        })

      # Create source metadata files
      File.mkdir_p!(Path.join(old_dir, "Season 2025"))

      FilesystemUtils.write_p!(
        Path.join(old_dir, "tvshow.nfo"),
        "<?xml version='1.0'?><tvshow></tvshow>"
      )

      FilesystemUtils.write_p!(Path.join(old_dir, "poster.jpg"), "fake image data")
      FilesystemUtils.write_p!(Path.join(old_dir, "fanart.jpg"), "fake image data")

      # Create media items with files
      uploaded_at = ~U[2025-12-20 12:00:00Z]

      media_item1 =
        media_item_fixture(%{
          source_id: source.id,
          title: "Test Video 1",
          uploaded_at: uploaded_at,
          media_filepath: Path.join(old_dir, "Season 2025/s2025e122000 - Test Video 1.mp4"),
          nfo_filepath: Path.join(old_dir, "Season 2025/s2025e122000 - Test Video 1.nfo"),
          subtitle_filepaths: [
            ["en", Path.join(old_dir, "Season 2025/s2025e122000 - Test Video 1.en.srt")]
          ]
        })
        |> store_info_json(%{"upload_date" => "20251220"})

      media_item2 =
        media_item_fixture(%{
          source_id: source.id,
          title: "Test Video 2",
          uploaded_at: ~U[2025-12-16 12:00:00Z],
          media_filepath: Path.join(old_dir, "Season 2025/s2025e121600 - Test Video 2.mp4"),
          nfo_filepath: Path.join(old_dir, "Season 2025/s2025e121600 - Test Video 2.nfo")
        })
        |> store_info_json(%{"upload_date" => "20251216"})

      # Create media item files
      FilesystemUtils.write_p!(media_item1.media_filepath, "fake video data")
      FilesystemUtils.write_p!(media_item1.nfo_filepath, "<?xml version='1.0'?><episodedetails></episodedetails>")
      FilesystemUtils.write_p!(List.last(media_item1.subtitle_filepaths) |> List.last(), "fake subtitle data")

      FilesystemUtils.write_p!(media_item2.media_filepath, "fake video data")
      FilesystemUtils.write_p!(media_item2.nfo_filepath, "<?xml version='1.0'?><episodedetails></episodedetails>")

      # Update custom_name
      {:ok, updated_source} = Sources.update_source(source, %{custom_name: new_custom_name})

      # Mock the get_source_details call for rebuilding series_directory
      expect_series_directory_lookup(new_dir)

      # yt-dlp fills in the new output template for each media item
      expect_output_filepaths(
        Path.join(new_dir, "Season %(upload_date>%Y)S/s%(upload_date>%Y)Se%(upload_date>%m%d)S00 - %(title)S.%(ext)S"),
        %{
          media_item1.media_id => Path.join(new_dir, "Season 2025/s2025e122000 - Test Video 1.mp4"),
          media_item2.media_id => Path.join(new_dir, "Season 2025/s2025e121600 - Test Video 2.mp4")
        }
      )

      # Execute update_source_directory
      assert {:ok, _} = Sources.update_source_directory(updated_source)

      # Reload source and media items
      updated_source = Repo.reload!(updated_source) |> Repo.preload([:metadata, :media_profile])
      media_item1 = Repo.reload!(media_item1) |> Repo.preload([:metadata, source: :media_profile])
      media_item2 = Repo.reload!(media_item2) |> Repo.preload([:metadata, source: :media_profile])

      # Verify source paths are updated
      assert updated_source.series_directory == new_dir
      assert updated_source.nfo_filepath == Path.join(new_dir, "tvshow.nfo")
      assert updated_source.poster_filepath == Path.join(new_dir, "poster.jpg")
      assert updated_source.fanart_filepath == Path.join(new_dir, "fanart.jpg")

      # Verify source files were moved
      refute File.exists?(Path.join(old_dir, "tvshow.nfo"))
      assert File.exists?(Path.join(new_dir, "tvshow.nfo"))
      assert File.exists?(Path.join(new_dir, "poster.jpg"))
      assert File.exists?(Path.join(new_dir, "fanart.jpg"))

      # Verify media item paths are updated with new custom_name
      assert media_item1.media_filepath == Path.join(new_dir, "Season 2025/s2025e122000 - Test Video 1.mp4")
      assert media_item1.nfo_filepath == Path.join(new_dir, "Season 2025/s2025e122000 - Test Video 1.nfo")

      assert List.first(media_item1.subtitle_filepaths) |> List.last() ==
               Path.join(new_dir, "Season 2025/s2025e122000 - Test Video 1.en.srt")

      assert media_item2.media_filepath == Path.join(new_dir, "Season 2025/s2025e121600 - Test Video 2.mp4")
      assert media_item2.nfo_filepath == Path.join(new_dir, "Season 2025/s2025e121600 - Test Video 2.nfo")

      # Verify media item files were moved
      refute File.exists?(Path.join(old_dir, "Season 2025/s2025e122000 - Test Video 1.mp4"))
      assert File.exists?(Path.join(new_dir, "Season 2025/s2025e122000 - Test Video 1.mp4"))
      assert File.exists?(Path.join(new_dir, "Season 2025/s2025e122000 - Test Video 1.nfo"))
      assert File.exists?(Path.join(new_dir, "Season 2025/s2025e122000 - Test Video 1.en.srt"))

      refute File.exists?(Path.join(old_dir, "Season 2025/s2025e121600 - Test Video 2.mp4"))
      assert File.exists?(Path.join(new_dir, "Season 2025/s2025e121600 - Test Video 2.mp4"))
      assert File.exists?(Path.join(new_dir, "Season 2025/s2025e121600 - Test Video 2.nfo"))
    end

    test "skips missing files but still updates their paths in the database" do
      source = source_fixture(%{custom_name: "Old Name"})
      {:ok, updated_source} = Sources.update_source(source, %{custom_name: "New Name"})
      media_directory = Application.get_env(:pinchflat, :media_directory)

      # Mock get_source_details to succeed
      expect_series_directory_lookup(Path.join([media_directory, "shows", "New Name"]))

      # Create a media item with a file in a non-existent directory to cause an error
      media_item =
        media_item_fixture(%{
          source_id: source.id,
          media_filepath: "/nonexistent/path/video.mp4"
        })
        |> store_info_json()

      expect_output_filepaths(Path.join(media_directory, "%(title)S.%(ext)S"), %{
        media_item.media_id => Path.join(media_directory, "video.webm")
      })

      # The function should handle the error gracefully
      # Since the file doesn't exist, it should skip moving it but still update the database
      # if the path calculation succeeds
      result = Sources.update_source_directory(updated_source)

      # Should succeed even if some files don't exist
      assert {:ok, _} = result
      assert Repo.reload!(media_item).media_filepath != media_item.media_filepath
    end

    test "returns an error without moving files or updating the database when the series directory lookup fails" do
      %{source: source, media_item: media_item, new_dir: new_dir, old_files: old_files} =
        source_with_files_to_move()

      # yt-dlp itself fails, so get_source_details returns an error
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl -> {:error, "some error", 1} end)

      assert {:error, changeset} = Sources.update_source_directory(source)
      assert %{series_directory: ["could not determine the new series directory"]} = errors_on(changeset)

      Enum.each(old_files, fn path -> assert File.read!(path) == "contents of #{path}" end)
      refute File.exists?(new_dir)
      assert Repo.reload!(source).series_directory == source.series_directory
      assert Repo.reload!(media_item).media_filepath == media_item.media_filepath
    end

    test "moves the media items when the output template has no season folder" do
      %{source: source, media_item: media_item} =
        source_with_files_to_move(
          %{output_path_template: %Pinchflat.Profiles.MediaProfile{}.output_path_template},
          %{series_directory: nil, poster_filepath: nil, nfo_filepath: nil}
        )

      # The lookup works, but a path with no season folder has no series directory
      new_media_filepath = default_template_media_filepath(source)
      expect_source_details_filepath(new_media_filepath)
      expect_output_filepaths(default_output_template(source), %{"episode1" => new_media_filepath})

      assert {:ok, _} = Sources.update_source_directory(source)

      refute File.exists?(media_item.media_filepath)
      assert File.read!(new_media_filepath) == "contents of #{media_item.media_filepath}"
      assert Repo.reload!(media_item).media_filepath == new_media_filepath
      assert Repo.reload!(source).series_directory == nil
    end

    test "leaves the source's series directory, images and NFO alone when the output template has no season folder" do
      %{source: source, media_item: media_item} =
        source_with_files_to_move(%{output_path_template: %Pinchflat.Profiles.MediaProfile{}.output_path_template})

      new_media_filepath = default_template_media_filepath(source)
      expect_source_details_filepath(new_media_filepath)
      expect_output_filepaths(default_output_template(source), %{"episode1" => new_media_filepath})

      assert {:ok, _} = Sources.update_source_directory(source)

      reloaded_source = Repo.reload!(source)
      assert reloaded_source.series_directory == source.series_directory
      assert reloaded_source.poster_filepath == source.poster_filepath
      assert reloaded_source.nfo_filepath == source.nfo_filepath
      assert File.read!(source.poster_filepath) == "contents of #{source.poster_filepath}"
      assert File.read!(source.nfo_filepath) == "contents of #{source.nfo_filepath}"

      assert Repo.reload!(media_item).media_filepath == new_media_filepath
      assert File.read!(new_media_filepath) == "contents of #{media_item.media_filepath}"
    end

    test "moves existing images and NFOs even when the profile no longer downloads them" do
      %{source: source, media_item: media_item, old_dir: old_dir, new_dir: new_dir, old_files: old_files} =
        source_with_files_to_move(%{download_source_images: false, download_nfo: false})

      expect_series_directory_lookup(new_dir)
      expect_episode_output_filepath(new_dir)

      assert {:ok, _} = Sources.update_source_directory(source)

      # They may have been downloaded before the profile's options were turned off, so they still move
      reloaded_source = Repo.reload!(source)
      assert reloaded_source.series_directory == new_dir
      assert reloaded_source.poster_filepath == Path.join(new_dir, "poster.jpg")
      assert reloaded_source.nfo_filepath == Path.join(new_dir, "tvshow.nfo")
      assert Repo.reload!(media_item).nfo_filepath == Path.join(new_dir, "Season 2025/s2025e122000 - Episode.nfo")

      assert regular_files_in(old_dir) == []

      Enum.each(old_files, fn old_path ->
        assert File.read!(String.replace(old_path, old_dir, new_dir)) == "contents of #{old_path}"
      end)
    end

    test "moves files back and leaves the database unchanged when a media item move fails" do
      %{source: source, media_item: media_item, new_dir: new_dir, old_files: old_files} =
        source_with_files_to_move()

      expect_series_directory_lookup(new_dir)
      expect_episode_output_filepath(new_dir)

      # The source's files and the media file move first, then the media item's NFO can't be
      # moved because a file is already at its destination (which must not be overwritten)
      blocking_filepath = Path.join(new_dir, "Season 2025/s2025e122000 - Episode.nfo")
      FilesystemUtils.write_p!(blocking_filepath, "someone else's file")

      assert {:error, changeset} = Sources.update_source_directory(source)
      assert [file_operations: {message, _}] = changeset.errors
      assert message =~ "could not move #{media_item.nfo_filepath} to #{blocking_filepath}"
      refute message =~ "could not be moved back"

      Enum.each(old_files, fn path -> assert File.read!(path) == "contents of #{path}" end)
      assert regular_files_in(new_dir) == [blocking_filepath]
      assert File.read!(blocking_filepath) == "someone else's file"

      reloaded_source = Repo.reload!(source)
      assert reloaded_source.series_directory == source.series_directory
      assert reloaded_source.poster_filepath == source.poster_filepath
      assert reloaded_source.nfo_filepath == source.nfo_filepath

      reloaded_media_item = Repo.reload!(media_item)
      assert reloaded_media_item.media_filepath == media_item.media_filepath
      assert reloaded_media_item.nfo_filepath == media_item.nfo_filepath
    end

    test "moves files back when the database update fails" do
      %{source: source, media_item: media_item, new_dir: new_dir, old_files: old_files} =
        source_with_files_to_move()

      expect_series_directory_lookup(new_dir)
      expect_episode_output_filepath(new_dir)

      # The column allows NULL but the changeset requires a title, so updating this media item
      # fails inside the transaction - after all the files have been moved
      media_item = media_item |> change(title: nil) |> Repo.update!()

      assert {:error, changeset} = Sources.update_source_directory(source)
      assert [file_operations: {message, _}] = changeset.errors
      assert message =~ "Database update failed"
      refute message =~ "could not be moved back"

      Enum.each(old_files, fn path -> assert File.read!(path) == "contents of #{path}" end)
      assert regular_files_in(new_dir) == []

      # The source was updated in the transaction before the media item failed, so this checks the rollback
      reloaded_source = Repo.reload!(source)
      assert reloaded_source.series_directory == source.series_directory
      assert reloaded_source.poster_filepath == source.poster_filepath
      assert reloaded_source.nfo_filepath == source.nfo_filepath

      reloaded_media_item = Repo.reload!(media_item)
      assert reloaded_media_item.media_filepath == media_item.media_filepath
      assert reloaded_media_item.nfo_filepath == media_item.nfo_filepath
    end

    test "leaves source metadata images in the internal metadata directory" do
      metadata_dir =
        Path.join([Application.get_env(:pinchflat, :metadata_directory), "sources", "#{:rand.uniform(1_000_000)}"])

      metadata_poster_filepath = Path.join(metadata_dir, "poster.jpg")
      FilesystemUtils.write_p!(metadata_poster_filepath, "metadata poster")

      %{source: source, new_dir: new_dir} =
        source_with_files_to_move(%{}, %{
          metadata: %{
            metadata_filepath: Path.join(metadata_dir, "metadata.json.gz"),
            poster_filepath: metadata_poster_filepath
          }
        })

      expect_series_directory_lookup(new_dir)
      expect_episode_output_filepath(new_dir)

      assert {:ok, updated_source} = Sources.update_source_directory(source)
      updated_source = Repo.preload(updated_source, :metadata, force: true)

      # The source's own poster moved and wasn't overwritten by the metadata poster of the same name
      assert updated_source.poster_filepath == Path.join(new_dir, "poster.jpg")
      assert File.read!(updated_source.poster_filepath) == "contents of #{source.poster_filepath}"

      assert updated_source.metadata.poster_filepath == metadata_poster_filepath
      assert File.read!(metadata_poster_filepath) == "metadata poster"
    end

    test "fills in the output template with yt-dlp, from the media item's stored info JSON" do
      %{source: source, media_item: media_item, new_dir: new_dir} =
        source_with_files_to_move(%{
          output_path_template:
            "shows/{{ source_custom_name }}/Season %(upload_date>%Y)S/%(channel)s - %(title)S.%(ext)S"
        })

      {:ok, stored_info_json} = MetadataFileHelpers.read_compressed_metadata(media_item.metadata.metadata_filepath)
      quality_options = DownloadOptionBuilder.build_quality_options_for(Repo.preload(source, :media_profile))

      expect_series_directory_lookup(new_dir)

      expect(YtDlpRunnerMock, :run, fn
        "--load-info-json=" <> info_json_filepath, :get_output_filepath, opts, _ot, _addl ->
          # yt-dlp gets the placeholders the app doesn't fill in, and the info JSON to fill them in from
          assert opts[:output] == Path.join(new_dir, "Season %(upload_date>%Y)S/%(channel)s - %(title)S.%(ext)S")
          assert info_json_filepath |> File.read!() |> Phoenix.json_library().decode!() == stored_info_json
          # As in a real download: they pick the format, which the filename can depend on
          assert Enum.all?(quality_options, &(&1 in opts))

          # This extension is the info JSON's, which can differ from the file on disk (e.g. before a merge)
          {:ok, Path.join(new_dir, "Season 2025/Some Channel - Episode.webm")}
      end)

      assert {:ok, _} = Sources.update_source_directory(source)

      new_media_filepath = Path.join(new_dir, "Season 2025/Some Channel - Episode.mp4")
      assert Repo.reload!(media_item).media_filepath == new_media_filepath
      assert File.read!(new_media_filepath) == "contents of #{media_item.media_filepath}"
      refute File.exists?(media_item.media_filepath)
    end

    test "keeps the paths of media items whose new path can't be worked out and moves the others" do
      %{source: source, media_item: media_item, old_dir: old_dir, new_dir: new_dir} = source_with_files_to_move()

      # One with no stored metadata, one whose stored info JSON is gone, one whose stored info JSON
      # is an empty file, and one yt-dlp fails for
      [no_metadata, info_json_gone, info_json_empty, ytdlp_fails] =
        Enum.map(["no_metadata", "info_json_gone", "info_json_empty", "ytdlp_fails"], fn media_id ->
          media_filepath = Path.join(old_dir, "Season 2025/#{media_id}.mp4")
          FilesystemUtils.write_p!(media_filepath, "contents of #{media_filepath}")

          media_item_fixture(%{source_id: source.id, media_id: media_id, media_filepath: media_filepath})
        end)

      info_json_gone = store_info_json(info_json_gone)
      File.rm!(info_json_gone.metadata.metadata_filepath)
      info_json_empty = store_info_json(info_json_empty)
      File.write!(info_json_empty.metadata.metadata_filepath, "")
      store_info_json(ytdlp_fails)

      expect_series_directory_lookup(new_dir)

      # yt-dlp only runs for the media items that have a stored info JSON
      expect(YtDlpRunnerMock, :run, 2, fn
        "--load-info-json=" <> info_json_filepath, :get_output_filepath, _opts, _ot, _addl ->
          case info_json_filepath |> File.read!() |> Phoenix.json_library().decode!() do
            %{"id" => "episode1"} -> {:ok, Path.join(new_dir, "Season 2025/s2025e122000 - Episode.mp4")}
            %{"id" => "ytdlp_fails"} -> {:error, "ERROR: something went wrong", 1}
          end
      end)

      assert {:ok, _} = Sources.update_source_directory(source)

      Enum.each([no_metadata, info_json_gone, info_json_empty, ytdlp_fails], fn skipped_media_item ->
        assert Repo.reload!(skipped_media_item).media_filepath == skipped_media_item.media_filepath
        assert File.read!(skipped_media_item.media_filepath) == "contents of #{skipped_media_item.media_filepath}"
      end)

      assert Repo.reload!(media_item).media_filepath == Path.join(new_dir, "Season 2025/s2025e122000 - Episode.mp4")
      refute File.exists?(media_item.media_filepath)
    end

    test "renames subtitles to follow the media file and leaves ones with no path alone" do
      %{source: source, media_item: media_item, old_dir: old_dir, new_dir: new_dir} = source_with_files_to_move()

      old_subtitle_filepaths = [
        ["en", Path.join(old_dir, "Season 2025/s2025e122000 - Episode.en.srt")],
        ["de", Path.join(old_dir, "Season 2025/s2025e122000 - Episode.de.vtt")]
      ]

      Enum.each(old_subtitle_filepaths, fn [_lang, path] -> FilesystemUtils.write_p!(path, "contents of #{path}") end)

      media_item =
        media_item
        |> change(subtitle_filepaths: old_subtitle_filepaths ++ [["fr", nil]])
        |> Repo.update!()

      # The media file's name changes, not just its directory
      expect_series_directory_lookup(new_dir)
      expect_episode_output_filepath(new_dir, "s2025e122000 - Renamed Episode.webm")

      assert {:ok, _} = Sources.update_source_directory(source)

      new_subtitle_filepaths = [
        ["en", Path.join(new_dir, "Season 2025/s2025e122000 - Renamed Episode.en.srt")],
        ["de", Path.join(new_dir, "Season 2025/s2025e122000 - Renamed Episode.de.vtt")]
      ]

      assert Repo.reload!(media_item).subtitle_filepaths == new_subtitle_filepaths ++ [["fr", nil]]

      old_subtitle_filepaths
      |> Enum.zip(new_subtitle_filepaths)
      |> Enum.each(fn {[_, old_path], [_, new_path]} ->
        refute File.exists?(old_path)
        assert File.read!(new_path) == "contents of #{old_path}"
      end)
    end

    test "renames a thumbnail next to the media file to follow it, keeping the thumbnail's extension" do
      %{source: source, media_item: media_item, old_dir: old_dir, new_dir: new_dir} = source_with_files_to_move()

      # Downloading stores it as "<media filepath without extension>-thumb.jpg"
      old_thumbnail_filepath = Path.join(old_dir, "Season 2025/s2025e122000 - Episode-thumb.jpg")
      FilesystemUtils.write_p!(old_thumbnail_filepath, "contents of #{old_thumbnail_filepath}")
      media_item = media_item |> change(thumbnail_filepath: old_thumbnail_filepath) |> Repo.update!()

      # The media file's name changes, not just its directory
      expect_series_directory_lookup(new_dir)
      expect_episode_output_filepath(new_dir, "s2025e122000 - Renamed Episode.webm")

      assert {:ok, _} = Sources.update_source_directory(source)

      new_thumbnail_filepath = Path.join(new_dir, "Season 2025/s2025e122000 - Renamed Episode-thumb.jpg")
      assert Repo.reload!(media_item).thumbnail_filepath == new_thumbnail_filepath
      assert File.read!(new_thumbnail_filepath) == "contents of #{old_thumbnail_filepath}"
      refute File.exists?(old_thumbnail_filepath)
    end

    test "moves the media item's .info.json to follow the media file and leaves its stored info JSON alone" do
      # Downloaded when the profile's metadata option was on. It's off now, but the file still moves
      %{source: source, media_item: media_item, old_dir: old_dir, new_dir: new_dir} =
        source_with_files_to_move(%{download_metadata: false})

      # yt-dlp wrote it as "<media filepath without extension>.info.json"
      old_info_json_filepath = Path.join(old_dir, "Season 2025/s2025e122000 - Episode.info.json")
      FilesystemUtils.write_p!(old_info_json_filepath, "contents of #{old_info_json_filepath}")
      media_item = media_item |> change(metadata_filepath: old_info_json_filepath) |> Repo.update!()

      # The media file's name changes, not just its directory
      expect_series_directory_lookup(new_dir)
      expect_episode_output_filepath(new_dir, "s2025e122000 - Renamed Episode.webm")

      assert {:ok, _} = Sources.update_source_directory(source)

      new_info_json_filepath = Path.join(new_dir, "Season 2025/s2025e122000 - Renamed Episode.info.json")
      reloaded_media_item = media_item |> Repo.reload!() |> Repo.preload(:metadata)
      assert reloaded_media_item.metadata_filepath == new_info_json_filepath
      assert File.read!(new_info_json_filepath) == "contents of #{old_info_json_filepath}"
      refute File.exists?(old_info_json_filepath)

      # The stored info JSON is in the internal metadata directory, which doesn't depend on the media's path
      assert reloaded_media_item.metadata.metadata_filepath == media_item.metadata.metadata_filepath
      assert File.exists?(media_item.metadata.metadata_filepath)
    end

    test "sets predicted_media_filepath to the new media path" do
      %{source: source, media_item: media_item, old_dir: old_dir, new_dir: new_dir} = source_with_files_to_move()

      # Downloading sets it to yt-dlp's filename, which can have a different extension
      media_item =
        media_item
        |> change(predicted_media_filepath: Path.join(old_dir, "Season 2025/s2025e122000 - Episode.webm"))
        |> Repo.update!()

      expect_series_directory_lookup(new_dir)
      expect_episode_output_filepath(new_dir)

      assert {:ok, _} = Sources.update_source_directory(source)

      assert Repo.reload!(media_item).predicted_media_filepath ==
               Path.join(new_dir, "Season 2025/s2025e122000 - Episode.mp4")
    end
  end

  describe "change_source/3 when testing original_url validation" do
    test "succeeds when an original URL is valid" do
      source = source_fixture()

      valid_urls = [
        "https://www.youtube.com/channel/UCkRfArvrzheW2E7b6SVT7vQ",
        "https://www.youtube.com/channel/UCkRfArvrzheW2E7b6SVT7vQ/videos",
        "https://www.youtube.com/@youtubecreators/featured",
        "https://www.youtube.com/@youtubecreators",
        "https://www.youtube.com/c/YouTubeCreators",
        "https://www.youtube.com/user/YouTubeCreators",
        "https://www.youtube.com/YouTubeCreators",
        "https://www.youtube.com/playlist?list=PLpjK416fmKwRtq-9-O_NbZlkW0k6zu2Wn",
        "https://www.youtube.com/playlist?list=UUkRfArvrzheW2E7b6SVT7vQ"
      ]

      Enum.each(valid_urls, fn url ->
        assert %{errors: []} = Sources.change_source(source, %{original_url: url})
      end)
    end

    test "fails when an original URL points to a video" do
      source = source_fixture()

      invalid_urls = [
        "https://www.youtube.com/watch?v=72maj9FLQZI",
        "https://youtu.be/72maj9FLQZI",
        "https://www.youtube.com/watch?v=1FwGFhMAmBo&list=PLpjK416fmKwRtq-9-O_NbZlkW0k6zu2Wn",
        "https://www.youtube.com/shorts/Dq0eH-ZhQTU",
        "https://www.youtube.com/embed/X64LHlfx4qg"
      ]

      Enum.each(invalid_urls, fn url ->
        assert %{errors: [_]} = Sources.change_source(source, %{original_url: url})
      end)
    end

    test "passes when a non-youtube link is provided" do
      source = source_fixture()

      valid_urls = [
        "https://www.example.com",
        "https://www.example.com/playlist",
        "https://www.example.com/channel",
        "https://www.example.com/user",
        "https://www.example.com/watch?v=72maj9FLQZI",
        "https://www.example.com/embed/X64LHlfx4qg"
      ]

      Enum.each(valid_urls, fn url ->
        assert %{errors: []} = Sources.change_source(source, %{original_url: url})
      end)
    end
  end

  defp playlist_mock(_url, :get_source_details, _opts, _ot, _addl) do
    {:ok, playlist_return()}
  end

  defp channel_mock(_url, :get_source_details, _opts, _ot, _addl) do
    {:ok, channel_return()}
  end

  defp playlist_return do
    Phoenix.json_library().encode!(%{
      channel: nil,
      channel_id: nil,
      playlist_id: "some_playlist_id_#{:rand.uniform(1_000_000)}",
      playlist_title: "some playlist name"
    })
  end

  defp channel_return do
    channel_id = "some_channel_id_#{:rand.uniform(1_000_000)}"

    Phoenix.json_library().encode!(%{
      channel: "some channel name",
      channel_id: channel_id,
      playlist_id: channel_id,
      playlist_title: "some channel name - videos"
    })
  end

  # A source renamed from "Old <n>" to "New <n>" whose files are still in the old series
  # directory: a poster and NFO, plus one media item with a media file, NFO and stored info JSON
  defp source_with_files_to_move(profile_attrs \\ %{}, source_attrs \\ %{}) do
    suffix = :rand.uniform(1_000_000)
    shows_dir = Path.join(Application.get_env(:pinchflat, :media_directory), "shows")
    old_dir = Path.join(shows_dir, "Old #{suffix}")
    new_dir = Path.join(shows_dir, "New #{suffix}")

    media_profile =
      media_profile_fixture(
        Map.merge(
          %{
            output_path_template:
              "shows/{{ source_custom_name }}/Season %(upload_date>%Y)S/s%(upload_date>%Y)Se%(upload_date>%m%d)S00 - %(title)S.%(ext)S",
            download_source_images: true,
            download_nfo: true
          },
          profile_attrs
        )
      )

    source =
      source_fixture(
        Map.merge(
          %{
            custom_name: "New #{suffix}",
            media_profile_id: media_profile.id,
            series_directory: old_dir,
            poster_filepath: Path.join(old_dir, "poster.jpg"),
            nfo_filepath: Path.join(old_dir, "tvshow.nfo")
          },
          source_attrs
        )
      )

    media_item =
      media_item_fixture(%{
        source_id: source.id,
        media_id: "episode1",
        title: "Episode",
        uploaded_at: ~U[2025-12-20 12:00:00Z],
        media_filepath: Path.join(old_dir, "Season 2025/s2025e122000 - Episode.mp4"),
        nfo_filepath: Path.join(old_dir, "Season 2025/s2025e122000 - Episode.nfo")
      })
      |> store_info_json(%{"channel" => "Some Channel", "upload_date" => "20251220"})

    old_files =
      Enum.filter(
        [source.poster_filepath, source.nfo_filepath, media_item.media_filepath, media_item.nfo_filepath],
        &is_binary/1
      )

    Enum.each(old_files, fn path -> FilesystemUtils.write_p!(path, "contents of #{path}") end)

    %{source: source, media_item: media_item, old_dir: old_dir, new_dir: new_dir, old_files: old_files}
  end

  defp expect_series_directory_lookup(series_directory) do
    expect_source_details_filepath(Path.join(series_directory, "Season 2025/s2025e122000 - Episode.mp4"))
  end

  defp expect_source_details_filepath(filepath) do
    expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
      {:ok, Phoenix.json_library().encode!(%{filename: filepath, channel: "Test", channel_id: "UC123"})}
    end)
  end

  # Expects yt-dlp to fill in `output_template` for each media item in `filenames_by_media_id`,
  # from the item's stored info JSON, and returns the item's filename
  defp expect_output_filepaths(output_template, filenames_by_media_id) do
    expect(YtDlpRunnerMock, :run, map_size(filenames_by_media_id), fn
      "--load-info-json=" <> info_json_filepath, :get_output_filepath, opts, _ot, _addl ->
        assert opts[:output] == output_template
        assert %{"id" => media_id} = info_json_filepath |> File.read!() |> Phoenix.json_library().decode!()

        {:ok, Map.fetch!(filenames_by_media_id, media_id)}
    end)
  end

  # Expects yt-dlp to fill in the season template for source_with_files_to_move/2's media item
  # in `series_directory`, and returns `filename` in the season folder
  defp expect_episode_output_filepath(series_directory, filename \\ "s2025e122000 - Episode.mp4") do
    expect_output_filepaths(
      Path.join(
        series_directory,
        "Season %(upload_date>%Y)S/s%(upload_date>%Y)Se%(upload_date>%m%d)S00 - %(title)S.%(ext)S"
      ),
      %{"episode1" => Path.join([series_directory, "Season 2025", filename])}
    )
  end

  # Stores an info JSON for the media item the way a download does: the item's id and title, plus `info`
  defp store_info_json(media_item, info \\ %{}) do
    info_json = Map.merge(%{"id" => media_item.media_id, "title" => media_item.title}, info)
    metadata_filepath = MetadataFileHelpers.compress_and_store_metadata_for(media_item, info_json)
    thumbnail_filepath = Path.join(Path.dirname(metadata_filepath), "thumbnail.jpg")
    metadata = %{metadata_filepath: metadata_filepath, thumbnail_filepath: thumbnail_filepath}

    {:ok, media_item} = Pinchflat.Media.update_media_item(Repo.preload(media_item, :metadata), %{metadata: metadata})
    media_item
  end

  # Where the default output template ("/{{ source_custom_name }}/{{ upload_yyyy_mm_dd }} {{ title }}/...")
  # puts the media item from source_with_files_to_move/2. It has no season folder
  defp default_template_media_filepath(source) do
    Path.join([
      Application.get_env(:pinchflat, :media_directory),
      source.custom_name,
      "2025-12-20 Episode",
      "Episode [episode1].mp4"
    ])
  end

  # The default output template for source_with_files_to_move/2's source, as yt-dlp gets it
  defp default_output_template(source) do
    Path.join([
      Application.get_env(:pinchflat, :media_directory),
      source.custom_name,
      "%(upload_date>%Y-%m-%d)S %(title)S",
      "%(title)S [%(id)S].%(ext)S"
    ])
  end

  defp regular_files_in(directory) do
    directory
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end
end
