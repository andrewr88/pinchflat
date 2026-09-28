defmodule Pinchflat.Sources.SourceDirectoryUpdateWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Sources.SourceDirectoryUpdateWorker

  describe "kickoff_with_task/1" do
    test "starts the worker" do
      source = source_fixture()

      assert [] = all_enqueued(worker: SourceDirectoryUpdateWorker)
      assert {:ok, _} = SourceDirectoryUpdateWorker.kickoff_with_task(source)
      assert [_] = all_enqueued(worker: SourceDirectoryUpdateWorker, args: %{"id" => source.id})
    end

    test "attaches a task" do
      source = source_fixture()

      assert {:ok, task} = SourceDirectoryUpdateWorker.kickoff_with_task(source)
      assert task.source_id == source.id
    end

    test "does not enqueue another job for the source while one is queued" do
      source = source_fixture()

      assert {:ok, _} = SourceDirectoryUpdateWorker.kickoff_with_task(source)
      assert {:error, :duplicate_job} = SourceDirectoryUpdateWorker.kickoff_with_task(source)
      assert [_] = all_enqueued(worker: SourceDirectoryUpdateWorker)
    end

    test "does not enqueue another job for the source while one is running" do
      source = source_fixture()
      {:ok, task} = SourceDirectoryUpdateWorker.kickoff_with_task(source)
      set_job_state(task, "executing")

      assert {:error, :duplicate_job} = SourceDirectoryUpdateWorker.kickoff_with_task(source)
      assert [] = all_enqueued(worker: SourceDirectoryUpdateWorker)
    end

    test "enqueues a new job for the source once the last one has completed or failed" do
      for state <- ["completed", "discarded"] do
        source = source_fixture()
        {:ok, task} = SourceDirectoryUpdateWorker.kickoff_with_task(source)
        set_job_state(task, state)

        assert {:ok, _} = SourceDirectoryUpdateWorker.kickoff_with_task(source)
      end
    end

    test "enqueues a job for each source" do
      assert {:ok, _} = SourceDirectoryUpdateWorker.kickoff_with_task(source_fixture())
      assert {:ok, _} = SourceDirectoryUpdateWorker.kickoff_with_task(source_fixture())

      assert [_, _] = all_enqueued(worker: SourceDirectoryUpdateWorker)
    end
  end

  describe "perform/1" do
    setup do
      suffix = :rand.uniform(1_000_000)
      shows_dir = Path.join(Application.get_env(:pinchflat, :media_directory), "shows")
      old_dir = Path.join(shows_dir, "Old #{suffix}")
      new_dir = Path.join(shows_dir, "New #{suffix}")
      old_nfo_filepath = Path.join(old_dir, "tvshow.nfo")

      source =
        source_fixture(%{
          custom_name: "New #{suffix}",
          media_profile_id: media_profile_fixture(%{download_nfo: true}).id,
          series_directory: old_dir,
          nfo_filepath: old_nfo_filepath
        })

      FilesystemUtils.write_p!(old_nfo_filepath, "nfo contents")

      %{source: source, old_dir: old_dir, new_dir: new_dir, old_nfo_filepath: old_nfo_filepath}
    end

    test "moves the source's files to match its custom name", %{
      source: source,
      new_dir: new_dir,
      old_nfo_filepath: old_nfo_filepath
    } do
      expect_series_directory_lookup(new_dir)

      assert :ok = perform_job(SourceDirectoryUpdateWorker, %{id: source.id})

      source = Repo.reload!(source)
      assert source.series_directory == new_dir
      assert source.nfo_filepath == Path.join(new_dir, "tvshow.nfo")
      assert File.read!(source.nfo_filepath) == "nfo contents"
      refute File.exists?(old_nfo_filepath)
    end

    test "returns the update's errors when it fails", %{source: source, old_dir: old_dir} do
      expect_failed_series_directory_lookup()

      assert {:error, "series_directory: could not determine the new series directory"} =
               perform_job(SourceDirectoryUpdateWorker, %{id: source.id})

      assert Repo.reload!(source).series_directory == old_dir
    end

    test "records a failed update as an error and does not retry it", %{source: source} do
      expect_failed_series_directory_lookup()
      {:ok, task} = SourceDirectoryUpdateWorker.kickoff_with_task(source)

      assert %{discard: 1} = Oban.drain_queue(queue: :local_data)

      job = Repo.get!(Oban.Job, task.job_id)
      assert job.state == "discarded"
      assert job.attempt == 1
      assert [%{"error" => error}] = job.errors
      assert error =~ "could not determine the new series directory"
    end
  end

  defp set_job_state(task, state) do
    Oban.Job
    |> where([j], j.id == ^task.job_id)
    |> Repo.update_all(set: [state: state])
  end

  defp expect_series_directory_lookup(series_directory) do
    expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
      filepath = Path.join(series_directory, "Season 2025/s2025e122000 - Episode.mp4")

      {:ok, Phoenix.json_library().encode!(%{filename: filepath, channel: "Test", channel_id: "UC123"})}
    end)
  end

  # yt-dlp itself fails, so the update stops before moving anything
  defp expect_failed_series_directory_lookup do
    expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl -> {:error, "some error", 1} end)
  end
end
