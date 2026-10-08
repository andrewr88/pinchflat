defmodule Pinchflat.FastIndexing.FastIndexingHelpersTest do
  use Pinchflat.DataCase

  import Pinchflat.TasksFixtures
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Settings
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.FastIndexing.FastIndexingWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.FastIndexing.FastIndexingHelpers

  setup do
    stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
      {:ok, media_attributes_return_fixture()}
    end)

    {:ok, [source: source_fixture()]}
  end

  describe "kickoff_indexing_task/1" do
    test "deletes any existing fast indexing tasks", %{source: source} do
      {:ok, job} = Oban.insert(FastIndexingWorker.new(%{"id" => source.id}))
      task = task_fixture(source_id: source.id, job_id: job.id)

      assert Repo.reload!(task)
      assert {:ok, _} = FastIndexingHelpers.kickoff_indexing_task(source)
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(task) end
    end

    test "kicks off a new fast indexing task", %{source: source} do
      assert {:ok, _} = FastIndexingHelpers.kickoff_indexing_task(source)
      assert [worker] = all_enqueued(worker: FastIndexingWorker)
      assert worker.args["id"] == source.id
    end
  end

  describe "index_and_kickoff_downloads/1" do
    test "enqueues a worker for each new media_id in the source's RSS feed", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [media_item] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert [worker] = all_enqueued(worker: MediaDownloadWorker)
      assert worker.args["id"] == media_item.id
      assert worker.priority == 0
    end

    test "creates media that another source already has and enqueues its download", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>video1</yt:videoId>"} end)
      # The stubbed yt-dlp response is for video1 too
      media_item_fixture(source_id: source_fixture().id, media_id: "video1")

      assert [media_item] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert %MediaItem{source_id: source_id, media_id: "video1"} = media_item
      assert source_id == source.id
      assert [worker] = all_enqueued(worker: MediaDownloadWorker)
      assert worker.args["id"] == media_item.id
    end

    test "does not enqueue a new worker for the source's media IDs we already know about", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)
      media_item_fixture(source_id: source.id, media_id: "test_1")

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "kicks off a download task for all pending media but at a lower priority", %{source: source} do
      pending_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert [worker_1, _worker_2] = all_enqueued(worker: MediaDownloadWorker)
      assert worker_1.args["id"] == pending_item.id
      assert worker_1.priority == 1
    end

    test "returns nothing but still kicks off pending downloads if media IDs can't be fetched", %{source: source} do
      pending_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:error, "HTTP request failed with status code 500: Internal Server Error"}
      end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert [worker] = all_enqueued(worker: MediaDownloadWorker)
      assert worker.args["id"] == pending_item.id
    end

    test "returns the found media items", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not enqueue a download job if the source does not allow it" do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)
      source = source_fixture(%{download_media: false})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "creates a download task record", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [media_item] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert [_] = Tasks.list_tasks_for(media_item, "MediaDownloadWorker")
    end

    test "passes the source's download options to the yt-dlp runner", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, opts, _ot, _addl_opts ->
        assert {:output, "/tmp/test/media/%(title)S.%(ext)S"} in opts
        assert {:remux_video, "mp4"} in opts
        {:ok, media_attributes_return_fixture()}
      end)

      FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not enqueue a download job if the media item does not match the format rules" do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      profile = media_profile_fixture(%{shorts_behaviour: :exclude})
      source = source_fixture(%{media_profile_id: profile.id})

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        output =
          Phoenix.json_library().encode!(%{
            id: "video2",
            title: "Video 2",
            original_url: "https://example.com/shorts/video2",
            live_status: "is_live",
            description: "desc2",
            aspect_ratio: 1.67,
            duration: 345.67,
            upload_date: "20210101"
          })

        {:ok, output}
      end)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "does not blow up if a media item cannot be created", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        {:ok, "{}"}
      end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not blow up if a media item causes a yt-dlp error", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        {:error, "message", 1}
      end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end
  end

  describe "index_and_kickoff_downloads/1 when testing cookies" do
    test "sets use_cookies if the source uses cookies" do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, addl ->
        assert {:use_cookies, true} in addl

        {:ok, media_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :all_operations})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not set use_cookies if the source uses cookies when needed" do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, addl ->
        assert {:use_cookies, false} in addl

        {:ok, media_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :when_needed})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not set use_cookies if the source does not use cookies" do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, addl ->
        assert {:use_cookies, false} in addl

        {:ok, media_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :disabled})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end
  end

  describe "index_and_kickoff_downloads/1 when testing backends" do
    test "uses the YouTube API if it is enabled", %{source: source} do
      expect(HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url =~ "https://youtube.googleapis.com/youtube/v3/playlistItems"

        {:ok, "{}"}
      end)

      Settings.set(youtube_api_key: "test_key")

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "the YouTube API creates records as expected", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, ~s({ "items": [ {"contentDetails": {"videoId": "test_1"}} ] })}
      end)

      Settings.set(youtube_api_key: "test_key")

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "RSS is used as a backup if the API fails", %{source: source} do
      expect(HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url =~ "https://youtube.googleapis.com/youtube/v3/playlistItems"

        {:error, ""}
      end)

      expect(HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url =~ "https://www.youtube.com/feeds/videos.xml"

        {:ok, "<yt:videoId>test_1</yt:videoId>"}
      end)

      Settings.set(youtube_api_key: "test_key")

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "RSS is used if the API is not enabled", %{source: source} do
      expect(HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url =~ "https://www.youtube.com/feeds/videos.xml"

        {:ok, "<yt:videoId>test_1</yt:videoId>"}
      end)

      Settings.set(youtube_api_key: nil)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end
  end

  describe "index_and_kickoff_downloads/1 for a channel that scans its tabs" do
    setup do
      stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>media_1</yt:videoId>"} end)

      {:ok, source: source_fixture(collection_type: :channel, original_url: "https://www.youtube.com/@tabbed")}
    end

    test "only creates the media whose tab the channel scans", %{source: source} do
      for {field, left_out_type} <- [index_videos: :video, index_shorts: :short, index_livestreams: :livestream],
          media_type <- [:video, :short, :livestream] do
        media_id = "#{field}_#{media_type}"
        stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<yt:videoId>#{media_id}</yt:videoId>"} end)

        stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
          {:ok, typed_media_json(media_id, media_type)}
        end)

        source = Map.put(source, field, false)
        expected_count = if media_type == left_out_type, do: 0, else: 1

        assert length(FastIndexingHelpers.index_and_kickoff_downloads(source)) == expected_count, media_id
        assert Repo.aggregate(where(MediaItem, media_id: ^media_id), :count) == expected_count, media_id
      end
    end

    test "creates every type of media for one of a channel's tabs" do
      source = source_fixture(collection_type: :channel, original_url: "https://www.youtube.com/@tabbed/videos")
      source = source |> Sources.change_source(%{index_shorts: false, index_livestreams: false}) |> Repo.update!()

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        {:ok, typed_media_json("short_1", :short)}
      end)

      assert [%MediaItem{short_form_content: true}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "doesn't fetch media it skipped again unless the channel scans its tab by then", %{source: source} do
      source = source |> Sources.change_source(%{index_shorts: false}) |> Repo.update!()
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl -> {:ok, short_json()} end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      stub(YtDlpRunnerMock, :run, fn _url, _action, _opts, _ot, _addl -> flunk("Fetched skipped media again") end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      source = source |> Sources.change_source(%{index_shorts: true}) |> Repo.update!()
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl -> {:ok, short_json()} end)

      assert [%MediaItem{short_form_content: true}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    # It can turn out to be a regular video, eg: a premiere
    test "fetches a livestream it skipped again if it hadn't happened yet", %{source: source} do
      source = source |> Sources.change_source(%{index_livestreams: false}) |> Repo.update!()

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        {:ok, typed_media_json("media_1", :upcoming)}
      end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        {:ok, typed_media_json("media_1", :video)}
      end)

      assert [%MediaItem{livestream: false}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end
  end

  defp short_json, do: typed_media_json("media_1", :short)

  # Like yt-dlp's output for each type of media. Fast indexing fetches media by its /watch URL so whether
  # it's a short is only told by its length and aspect ratio
  defp typed_media_json(media_id, type) do
    {live_status, aspect_ratio, duration} =
      case type do
        :video -> {"not_live", 1.78, 600}
        :short -> {"not_live", 0.56, 30}
        :livestream -> {"was_live", 1.78, 3600}
        :upcoming -> {"is_upcoming", 1.78, nil}
      end

    Phoenix.json_library().encode!(%{
      id: media_id,
      title: "Media #{media_id}",
      original_url: "https://www.youtube.com/watch?v=#{media_id}",
      live_status: live_status,
      description: "desc",
      aspect_ratio: aspect_ratio,
      duration: duration,
      upload_date: "20210101"
    })
  end
end
