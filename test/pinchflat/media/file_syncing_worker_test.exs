defmodule Pinchflat.Media.FileSyncingWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Media.FileSyncingWorker

  describe "kickoff_with_task/3" do
    test "starts the worker" do
      source = source_fixture()

      assert [] = all_enqueued(worker: FileSyncingWorker)
      assert {:ok, _} = FileSyncingWorker.kickoff_with_task(source)
      assert [_] = all_enqueued(worker: FileSyncingWorker)
    end

    test "attaches a task" do
      source = source_fixture()

      assert {:ok, task} = FileSyncingWorker.kickoff_with_task(source)
      assert task.source_id == source.id
    end
  end

  describe "perform/1" do
    test "clears the paths of missing files and keeps the files that still exist" do
      source = source_fixture()
      present_media_item = media_item_with_attachments(%{source_id: source.id})
      missing_media_item = media_item_fixture(%{source_id: source.id, media_filepath: "/tmp/missing.mp4"})

      assert :ok = perform_job(FileSyncingWorker, %{"id" => source.id})

      assert filepaths(Repo.reload!(present_media_item)) == filepaths(present_media_item)
      refute Repo.reload!(missing_media_item).media_filepath
    end

    # An unmounted media directory makes every file look missing. Clearing their paths would make
    # the whole source pending, and the next index would download all of it again
    test "doesn't change anything if none of the source's downloaded media files exist" do
      # Keeps the media directory from being empty, so it's the source's missing files that stop the sync
      _other_media_item = media_item_with_attachments()
      source = source_fixture()

      missing_directory =
        Path.join(Application.get_env(:pinchflat, :media_directory), "missing #{:rand.uniform(1_000_000)}")

      media_items =
        for n <- 1..3 do
          media_item_fixture(%{
            source_id: source.id,
            media_filepath: Path.join(missing_directory, "#{n}.mp4"),
            thumbnail_filepath: Path.join(missing_directory, "#{n}.jpg"),
            subtitle_filepaths: [["en", Path.join(missing_directory, "#{n}.en.srt")]]
          })
        end

      result = perform_job(FileSyncingWorker, %{"id" => source.id})

      for media_item <- media_items do
        refute Media.pending_download?(media_item)
        assert filepaths(Repo.reload!(media_item)) == filepaths(media_item)
      end

      assert {:error, reason} = result
      assert reason =~ "none of the source's 3 downloaded media files exist"
    end
  end

  describe "perform/1 when the media directory is missing or empty" do
    setup do
      original_media_directory = Application.get_env(:pinchflat, :media_directory)
      on_exit(fn -> Application.put_env(:pinchflat, :media_directory, original_media_directory) end)

      source = source_fixture()
      # One of the source's media files exists (outside the media directory), so it's the
      # media directory itself that stops the sync
      present_filepath = FilesystemUtils.generate_metadata_tmpfile(:mp4)
      on_exit(fn -> File.rm(present_filepath) end)
      _present_media_item = media_item_fixture(%{source_id: source.id, media_filepath: present_filepath})
      missing_media_item = media_item_fixture(%{source_id: source.id, media_filepath: "/tmp/missing.mp4"})

      %{source: source, missing_media_item: missing_media_item}
    end

    test "doesn't change anything if the media directory is missing", context do
      media_directory = Path.join(System.tmp_dir!(), "missing_media_#{:rand.uniform(1_000_000)}")
      Application.put_env(:pinchflat, :media_directory, media_directory)

      assert {:error, reason} = perform_job(FileSyncingWorker, %{"id" => context.source.id})
      assert reason =~ "media directory #{inspect(media_directory)} is missing or empty"
      assert filepaths(Repo.reload!(context.missing_media_item)) == filepaths(context.missing_media_item)
    end

    test "doesn't change anything if the media directory is empty", context do
      media_directory = Path.join(System.tmp_dir!(), "empty_media_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(media_directory)
      on_exit(fn -> File.rmdir(media_directory) end)
      Application.put_env(:pinchflat, :media_directory, media_directory)

      assert {:error, reason} = perform_job(FileSyncingWorker, %{"id" => context.source.id})
      assert reason =~ "media directory #{inspect(media_directory)} is missing or empty"
      assert filepaths(Repo.reload!(context.missing_media_item)) == filepaths(context.missing_media_item)
    end
  end

  defp filepaths(media_item), do: Map.take(media_item, MediaItem.filepath_attributes())
end
