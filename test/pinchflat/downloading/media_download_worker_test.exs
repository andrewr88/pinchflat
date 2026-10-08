defmodule Pinchflat.Downloading.MediaDownloadWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.Downloading.MediaDownloadWorker

  setup do
    stub(YtDlpRunnerMock, :run, fn
      _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
      _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
    end)

    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)
    stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)

    media_item =
      %{media_filepath: nil}
      |> media_item_fixture()
      |> Repo.preload([:metadata, source: :media_profile])

    {:ok, %{media_item: media_item}}
  end

  describe "kickoff_with_task/2" do
    test "starts the worker", %{media_item: media_item} do
      assert [] = all_enqueued(worker: MediaDownloadWorker)
      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item)
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "attaches a task", %{media_item: media_item} do
      assert {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)
      assert task.media_item_id == media_item.id
    end

    test "can be called with additional job arguments", %{media_item: media_item} do
      job_args = %{"force" => true}

      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item, job_args)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id, "force" => true})
    end

    test "has a priority of 5 by default", %{media_item: media_item} do
      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item)

      [job] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      assert job.priority == 5
    end

    test "priority can be set", %{media_item: media_item} do
      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item, %{}, priority: 0)

      [job] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      assert job.priority == 0
    end

    test "doesn't queue a second download for a media item", %{media_item: media_item} do
      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item, %{quality_upgrade?: true})

      assert {:error, :duplicate_job} = MediaDownloadWorker.kickoff_with_task(media_item)
      assert {:error, :duplicate_job} = MediaDownloadWorker.kickoff_with_task(media_item, %{redownload?: true})
      assert [job] = all_enqueued(worker: MediaDownloadWorker)
      assert job.args == %{"id" => media_item.id, "quality_upgrade?" => true}
    end

    test "a forced download replaces a queued download", %{media_item: media_item} do
      assert {:ok, queued_task} = MediaDownloadWorker.kickoff_with_task(media_item)

      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item, %{force: true})
      assert [job] = all_enqueued(worker: MediaDownloadWorker)
      assert job.args == %{"id" => media_item.id, "force" => true}
      assert Repo.get!(Oban.Job, queued_task.job_id).state == "cancelled"
      refute Repo.reload(queued_task)
    end

    test "a forced download doesn't replace a running download", %{media_item: media_item} do
      assert {:ok, running_task} = MediaDownloadWorker.kickoff_with_task(media_item)
      Repo.update_all(where(Oban.Job, id: ^running_task.job_id), set: [state: "executing"])

      assert {:error, :duplicate_job} = MediaDownloadWorker.kickoff_with_task(media_item, %{force: true})
      assert Repo.get!(Oban.Job, running_task.job_id).state == "executing"
      assert Repo.reload(running_task)
    end
  end

  describe "perform/1" do
    setup do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      :ok
    end

    test "saves attributes to the media_item", %{media_item: media_item} do
      assert media_item.media_filepath == nil
      perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload(media_item)

      assert media_item.media_filepath != nil
    end

    test "saves the metadata to the media_item", %{media_item: media_item} do
      assert media_item.metadata == nil
      perform_job(MediaDownloadWorker, %{id: media_item.id})
      assert Repo.reload(media_item).metadata != nil
    end

    test "won't double-schedule downloading jobs", %{media_item: media_item} do
      Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))
      Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    # Two jobs for one media item would run yt-dlp twice at once, writing the same files
    test "won't schedule jobs with different args for the same media item", %{media_item: media_item} do
      other_media_item = media_item_fixture()

      for args <- [%{}, %{force: true}, %{quality_upgrade?: true}, %{redownload?: true}] do
        Oban.insert(MediaDownloadWorker.new(Map.put(args, :id, media_item.id)))
      end

      Oban.insert(MediaDownloadWorker.new(%{id: other_media_item.id, force: true}))

      assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
      assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => other_media_item.id})
    end

    test "sets the job to retryable if the download fails", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "error"}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

        assert job.state == "retryable"
      end)
    end

    test "sets the job to retryable if the download failed and was retried", %{media_item: media_item} do
      # A SponsorBlock error is retried once without SponsorBlock, so each call is made twice
      expect(YtDlpRunnerMock, :run, 4, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "Unable to communicate with SponsorBlock", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

        assert job.state == "retryable"
      end)
    end

    test "does not set the job to retryable if retrying wouldn't fix the issue", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "Something something Video unavailable something something", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id, quality_upgrade?: true}))

        assert job.state == "completed"
      end)
    end

    test "does not set the job to retryable if youtube thinks you're a bot", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "Sign in to confirm you're not a bot", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id, quality_upgrade?: true}))

        assert job.state == "completed"
      end)
    end

    test "does not set the job to retryable you aren't a member", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          {:error, "This video is available to this channel's members on level: foo", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id, quality_upgrade?: true}))

        assert job.state == "completed"
      end)
    end

    test "ensures error are returned in a 2-item tuple", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "error", 1}
      end)

      assert {:error, :download_failed} = perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download if the source is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Sources.update_source(media_item.source, %{download_media: false})

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download if the media item is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Media.update_media_item(media_item, %{prevent_download: true})

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "saves the file's size to the database", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          metadata = render_parsed_metadata(:media_metadata)
          FilesystemUtils.write_p!(metadata["filepath"], "test")

          {:ok, Phoenix.json_library().encode!(metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload(media_item)

      assert media_item.media_size_bytes > 0
    end

    test "does not set redownloaded_at by default", %{media_item: media_item} do
      perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload(media_item)

      assert media_item.media_redownloaded_at == nil
    end

    test "keeps the media item's files and doesn't run the media_downloaded script if the download fails" do
      media_item = media_item_with_attachments()

      # This replaces the stub, so running any other script fails the test
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 0} end)

      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "error", 1}
      end)

      assert {:error, :download_failed} = perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
      assert Repo.reload!(media_item).media_filepath == media_item.media_filepath
      assert File.exists?(media_item.media_filepath)
    end

    test "keeps the media item's files and doesn't run the media_downloaded script if the download can't be saved" do
      media_item = media_item_with_attachments()
      new_media_filepath = Path.join(Path.dirname(media_item.media_filepath), "upgraded.mkv")

      # This replaces the stub, so running any other script fails the test
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 0} end)

      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          FilesystemUtils.write_p!(new_media_filepath, "media")
          # A title like this is rejected by MediaItem's changeset, so saving fails
          {:ok, render_metadata_with(%{"filepath" => new_media_filepath, "title" => "youtube video #123"})}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      assert {:error, :download_failed} = perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
      assert Repo.reload!(media_item).media_filepath == media_item.media_filepath
      assert File.exists?(media_item.media_filepath)
    end

    test "does not blow up if the record doesn't exist" do
      assert :ok = perform_job(MediaDownloadWorker, %{id: 0})
    end

    test "sets the no_force_overwrites runner option", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          assert :no_force_overwrites in opts
          refute :force_overwrites in opts

          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download if the media item isn't pending download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Media.update_media_item(media_item, %{media_filepath: "foo.mp4"})

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end
  end

  # The first download attempt can't reach SponsorBlock, so it's retried without SponsorBlock, which succeeds
  describe "perform/1 when testing recovered downloads" do
    test "finishes the download like a successful one", %{media_item: media_item} do
      media_filepath = Path.join([Application.get_env(:pinchflat, :media_directory), "recovered", "media.mkv"])
      on_exit(fn -> File.rm_rf!(Path.dirname(media_filepath)) end)
      expect_recovered_download(media_filepath)

      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 0} end)

      expect(UserScriptRunnerMock, :run, fn :media_downloaded, data ->
        assert data.media_filepath == media_filepath

        {:ok, "", 0}
      end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload!(media_item)

      assert media_item.media_filepath == media_filepath
      assert media_item.media_size_bytes > 0
      assert media_item.last_error == "Unable to communicate with SponsorBlock"
    end

    test "finishes a quality upgrade without downloading it again" do
      old_media_item = media_item_with_attachments(%{media_downloaded_at: now_minus(10, :days)})
      new_media_filepath = Path.join(Path.dirname(old_media_item.media_filepath), "upgraded.mkv")
      expect_recovered_download(new_media_filepath)

      assert :ok = perform_job(MediaDownloadWorker, %{id: old_media_item.id, quality_upgrade?: true})
      media_item = Repo.reload!(old_media_item)

      assert media_item.media_filepath == new_media_filepath
      assert DateTime.diff(DateTime.utc_now(), media_item.media_redownloaded_at) < 2
      assert DateTime.diff(DateTime.utc_now(), media_item.media_downloaded_at) < 2
      assert File.exists?(new_media_filepath)
      refute File.exists?(old_media_item.media_filepath)
    end
  end

  describe "perform/1 when testing non-downloadable media" do
    test "does not retry the job if the media is currently not downloadable", %{media_item: media_item} do
      stub(YtDlpRunnerMock, :run, fn _url, :get_downloadable_status, _opts, _ot, _addl ->
        {:ok, Phoenix.json_library().encode!(%{"live_status" => "is_live"})}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

        assert job.state == "completed"
      end)
    end
  end

  describe "perform/1 when testing forced downloads" do
    test "ignores 'prevent_download' if forced", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      Sources.update_source(media_item.source, %{download_media: false})
      Media.update_media_item(media_item, %{prevent_download: true})

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
    end

    test "ignores whether the media item is pending when forced", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      Media.update_media_item(media_item, %{media_filepath: "foo.mp4"})

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
    end

    test "sets force_overwrites runner option", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          assert :force_overwrites in opts
          refute :no_force_overwrites in opts

          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
    end
  end

  describe "perform/1 when testing re-downloads" do
    test "sets redownloaded_at on the media_item", %{media_item: media_item} do
      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
      media_item = Repo.reload(media_item)

      assert media_item.media_redownloaded_at != nil
    end

    test "refreshes an earlier redownloaded_at", %{media_item: media_item} do
      {:ok, media_item} = Media.update_media_item(media_item, %{media_redownloaded_at: now_minus(5, :days)})

      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
      media_item = Repo.reload(media_item)

      assert DateTime.diff(DateTime.utc_now(), media_item.media_redownloaded_at) < 2
    end

    test "a forced download clears redownloaded_at", %{media_item: media_item} do
      {:ok, media_item} = Media.update_media_item(media_item, %{media_redownloaded_at: now_minus(5, :days)})

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
      media_item = Repo.reload(media_item)

      assert media_item.media_downloaded_at
      assert media_item.media_redownloaded_at == nil
    end

    test "ignores whether the media item is pending when re-downloaded", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      Media.update_media_item(media_item, %{media_filepath: "foo.mp4"})

      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
    end

    test "doesn't redownload if the source is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Sources.update_source(media_item.source, %{download_media: false})

      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
    end

    test "doesn't redownload if the media item is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Media.update_media_item(media_item, %{prevent_download: true})

      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
    end

    # Like any download that isn't forced. The media's existing files are kept
    test "a pre-download script veto prevents future downloads" do
      media_item = media_item_with_attachments()

      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 1} end)
      expect(YtDlpRunnerMock, :run, 0, fn _url, _action, _opts, _ot, _addl -> {:ok, ""} end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
      updated_media_item = Repo.reload!(media_item)

      assert updated_media_item.prevent_download
      assert updated_media_item.media_filepath == media_item.media_filepath
      assert File.exists?(media_item.media_filepath)
    end

    test "sets force_overwrites runner option", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          assert :force_overwrites in opts
          refute :no_force_overwrites in opts

          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
    end

    test "deletes old files if the media item has been updated" do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          tmp_media_item = media_item_with_attachments()
          metadata = render_parsed_metadata(:media_metadata)
          metadata = Map.put(metadata, "filepath", tmp_media_item.media_filepath)

          {:ok, Phoenix.json_library().encode!(metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      old_media_item = media_item_with_attachments()
      perform_job(MediaDownloadWorker, %{id: old_media_item.id, force: true})
      updated_media_item = Repo.reload(old_media_item)

      assert updated_media_item.media_filepath != old_media_item.media_filepath
      refute File.exists?(old_media_item.media_filepath)
      assert File.exists?(updated_media_item.media_filepath)
    end
  end

  describe "perform/1 when testing redownloads of existing media" do
    setup %{media_item: media_item} do
      {:ok, media_item} = Media.update_media_item(media_item, %{media_filepath: "foo.mp4"})

      {:ok, %{media_item: media_item}}
    end

    test "downloads already-downloaded media without overwriting it", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 0} end)
      expect(UserScriptRunnerMock, :run, fn :media_downloaded, _ -> {:ok, "", 0} end)

      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          assert :no_force_overwrites in opts
          refute :force_overwrites in opts

          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      # Runs the job exactly as the source's "Redownload Existing" action enqueues it
      assert [{:ok, _}] = DownloadingHelpers.kickoff_redownload_for_existing_media(media_item.source)
      assert [job] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      assert :ok = perform_job(MediaDownloadWorker, job.args)
    end

    test "doesn't redownload if the source is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)
      expect(UserScriptRunnerMock, :run, 0, fn _event, _data -> {:ok, "", 0} end)

      Sources.update_source(media_item.source, %{download_media: false})

      perform_job(MediaDownloadWorker, %{id: media_item.id, redownload?: true})
    end

    test "doesn't redownload if the media item is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)
      expect(UserScriptRunnerMock, :run, 0, fn _event, _data -> {:ok, "", 0} end)

      Media.update_media_item(media_item, %{prevent_download: true})

      perform_job(MediaDownloadWorker, %{id: media_item.id, redownload?: true})
    end

    test "doesn't download media that is no longer downloaded and isn't pending" do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      source = source_fixture(%{title_filter_regex: "(?i)^FOO$"})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      perform_job(MediaDownloadWorker, %{id: media_item.id, redownload?: true})
    end

    test "keeps the media item's redownloaded_at", %{media_item: media_item} do
      {:ok, media_item} = Media.update_media_item(media_item, %{media_redownloaded_at: now_minus(5, :days)})

      perform_job(MediaDownloadWorker, %{id: media_item.id, redownload?: true})
      updated_media_item = Repo.reload!(media_item)

      assert updated_media_item.media_downloaded_at
      assert updated_media_item.media_redownloaded_at == media_item.media_redownloaded_at
    end

    # The download date is what retention and quality upgrades go by, and the media file isn't replaced
    test "keeps the download date of a media file it leaves in place, so the media can still be upgraded" do
      media_item = upgradeable_media_item_with_attachments()
      assert media_item.id in Enum.map(Media.list_upgradeable_media_items(), & &1.id)
      # Like yt-dlp would, the download has the upload date the media was indexed with
      stub_download_to(media_item.media_filepath, %{"timestamp" => DateTime.to_unix(media_item.uploaded_at)})

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id, redownload?: true})
      updated_media_item = Repo.reload!(media_item)

      assert updated_media_item.media_downloaded_at == media_item.media_downloaded_at
      assert media_item.id in Enum.map(Media.list_upgradeable_media_items(), & &1.id)
    end

    test "sets the download date if the media is downloaded to a new path" do
      media_item = upgradeable_media_item_with_attachments()
      new_media_filepath = Path.join(Path.dirname(media_item.media_filepath), "renamed.mkv")
      stub_download_to(new_media_filepath)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id, redownload?: true})
      updated_media_item = Repo.reload!(media_item)

      assert updated_media_item.media_filepath == new_media_filepath
      assert DateTime.diff(DateTime.utc_now(), updated_media_item.media_downloaded_at) < 2
      refute File.exists?(media_item.media_filepath)
    end

    test "sets the download date if the media file was missing, since it's downloaded again" do
      media_item = upgradeable_media_item_with_attachments()
      File.rm!(media_item.media_filepath)
      stub_download_to(media_item.media_filepath)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id, redownload?: true})
      updated_media_item = Repo.reload!(media_item)

      assert DateTime.diff(DateTime.utc_now(), updated_media_item.media_downloaded_at) < 2
    end

    test "a pre-download script veto prevents future downloads", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 1} end)
      expect(YtDlpRunnerMock, :run, 0, fn _url, _action, _opts, _ot, _addl -> {:ok, ""} end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id, redownload?: true})
      media_item = Repo.reload!(media_item)

      assert media_item.prevent_download
      assert media_item.media_filepath == "foo.mp4"
    end
  end

  describe "perform/1 when testing user script callbacks" do
    test "calls the media_pre_download user script runner", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, data ->
        assert data.id == media_item.id

        {:ok, "", 0}
      end)

      expect(UserScriptRunnerMock, :run, fn :media_downloaded, _ -> {:ok, "", 0} end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download the media if the pre-download script returns an error", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 1} end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload!(media_item)

      refute media_item.media_filepath
      assert media_item.prevent_download
    end

    test "downloads media if the pre-download script is not present", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, :no_executable} end)
      expect(UserScriptRunnerMock, :run, fn :media_downloaded, _ -> {:ok, :no_executable} end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload!(media_item)

      assert media_item.media_filepath
      refute media_item.prevent_download
    end

    test "doesn't run the pre-download script if the media item isn't pending download", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, 0, fn _event, _data -> {:ok, "", 1} end)

      {:ok, media_item} = Media.update_media_item(media_item, %{media_filepath: "foo.mp4"})

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})
      refute Repo.reload!(media_item).prevent_download
    end

    test "doesn't run the pre-download script if the source is set to not download", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, 0, fn _event, _data -> {:ok, "", 1} end)

      Sources.update_source(media_item.source, %{download_media: false})

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})
      refute Repo.reload!(media_item).prevent_download
    end

    test "runs the pre-download script for forced downloads without letting it prevent them", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 1} end)
      expect(UserScriptRunnerMock, :run, fn :media_downloaded, _ -> {:ok, "", 0} end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
      media_item = Repo.reload!(media_item)

      assert media_item.media_filepath
      refute media_item.prevent_download
    end

    test "calls the media_downloaded user script runner", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 0} end)

      expect(UserScriptRunnerMock, :run, fn :media_downloaded, data ->
        assert data.id == media_item.id

        {:ok, "", 0}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end
  end

  defp render_metadata_with(attrs) do
    :media_metadata
    |> render_parsed_metadata()
    |> Map.merge(attrs)
    |> Phoenix.json_library().encode!()
  end

  # yt-dlp downloads the media to the given path (unless it's already there)
  defp stub_download_to(media_filepath, metadata_attrs \\ %{}) do
    stub(YtDlpRunnerMock, :run, fn
      _url, :get_downloadable_status, _opts, _ot, _addl ->
        {:ok, "{}"}

      _url, :download, _opts, _ot, _addl ->
        if !File.exists?(media_filepath), do: FilesystemUtils.write_p!(media_filepath, "media")

        {:ok, render_metadata_with(Map.put(metadata_attrs, "filepath", media_filepath))}

      _url, :download_thumbnail, _opts, _ot, _addl ->
        {:ok, ""}
    end)
  end

  # The first download fails to reach SponsorBlock, so it's retried without SponsorBlock. That
  # one downloads the media to the given path. Any other download would be unexpected
  defp expect_recovered_download(media_filepath) do
    expect(YtDlpRunnerMock, :run, 2, fn
      _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
      _url, :download, _opts, _ot, _addl -> {:error, "Unable to communicate with SponsorBlock", 1}
    end)

    expect(YtDlpRunnerMock, :run, 3, fn
      _url, :get_downloadable_status, _opts, _ot, _addl ->
        {:ok, "{}"}

      _url, :download, _opts, _ot, _addl ->
        FilesystemUtils.write_p!(media_filepath, "media")

        {:ok, render_metadata_with(%{"filepath" => media_filepath})}

      _url, :download_thumbnail, _opts, _ot, _addl ->
        {:ok, ""}
    end)
  end

  # Uploaded and downloaded 10 days ago, with a 2 day redownload delay
  defp upgradeable_media_item_with_attachments do
    media_profile = media_profile_fixture(%{redownload_delay_days: 2})
    source = source_fixture(%{media_profile_id: media_profile.id})
    ten_days_ago = now_minus(10, :days)

    media_item_with_attachments(%{source_id: source.id, uploaded_at: ten_days_ago, media_downloaded_at: ten_days_ago})
  end
end
