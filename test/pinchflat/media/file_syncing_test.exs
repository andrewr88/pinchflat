defmodule Pinchflat.Media.FileSyncingTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Media
  alias Pinchflat.Media.FileSyncing
  alias Pinchflat.Utils.FilesystemUtils

  describe "delete_outdated_files/2" do
    test "deletes outdated non-subtitle files" do
      new_media_item = media_item_with_attachments()
      old_media_item = media_item_with_attachments()

      assert :ok = FileSyncing.delete_outdated_files(old_media_item, new_media_item)

      assert File.exists?(new_media_item.media_filepath)
      refute File.exists?(old_media_item.media_filepath)
    end

    test "doesn't delete non-subtitle files if the new file is the same" do
      new_media_item = media_item_with_attachments()
      old_media_item = media_item_fixture(%{media_filepath: new_media_item.media_filepath})

      assert :ok = FileSyncing.delete_outdated_files(old_media_item, new_media_item)

      assert File.exists?(new_media_item.media_filepath)
      assert File.exists?(old_media_item.media_filepath)
    end

    test "doesn't delete the old file if the new file is missing that key" do
      new_media_item = media_item_fixture(%{media_filepath: nil})
      old_media_item = media_item_with_attachments()

      assert :ok = FileSyncing.delete_outdated_files(old_media_item, new_media_item)

      assert File.exists?(old_media_item.media_filepath)
    end

    test "deletes outdated subtitle files" do
      new_media_item = media_item_with_attachments()
      old_media_item = media_item_with_attachments()

      assert :ok = FileSyncing.delete_outdated_files(old_media_item, new_media_item)

      assert File.exists?(get_subtitle_filepath(new_media_item, "en"))
      refute File.exists?(get_subtitle_filepath(old_media_item, "en"))
    end

    test "keeps old subtitle files if the new file is the same" do
      new_media_item = media_item_with_attachments()
      old_media_item = media_item_fixture(%{subtitle_filepaths: new_media_item.subtitle_filepaths})

      assert :ok = FileSyncing.delete_outdated_files(old_media_item, new_media_item)

      assert File.exists?(get_subtitle_filepath(new_media_item, "en"))
      assert File.exists?(get_subtitle_filepath(old_media_item, "en"))
    end

    test "doesn't delete old subtitle files if the new file is missing that key" do
      new_media_item = media_item_fixture(%{subtitle_filepaths: []})
      old_media_item = media_item_with_attachments()

      assert :ok = FileSyncing.delete_outdated_files(old_media_item, new_media_item)

      assert File.exists?(get_subtitle_filepath(old_media_item, "en"))
    end

    # The paths come from yt-dlp
    test "doesn't delete outdated files outside the media directory" do
      new_media_item = media_item_with_attachments()
      outside_filepath = FilesystemUtils.generate_metadata_tmpfile(:mkv)
      outside_subtitle_filepath = FilesystemUtils.generate_metadata_tmpfile(:srt)

      old_media_item =
        media_item_fixture(%{media_filepath: outside_filepath, subtitle_filepaths: [["en", outside_subtitle_filepath]]})

      assert :ok = FileSyncing.delete_outdated_files(old_media_item, new_media_item)

      assert File.exists?(outside_filepath)
      assert File.exists?(outside_subtitle_filepath)

      File.rm!(outside_filepath)
      File.rm!(outside_subtitle_filepath)
    end
  end

  describe "sync_file_presence_on_disk/1" do
    test "removes attributes whose files are missing" do
      media_item = media_item_fixture(%{media_filepath: "/tmp/missing_file.mp4"})

      assert media_item.media_filepath
      assert [updated_media_item] = FileSyncing.sync_file_presence_on_disk([media_item])
      refute updated_media_item.media_filepath
    end

    test "doesn't remove attributes where the files still exist" do
      media_item = media_item_with_attachments()

      assert media_item.media_filepath
      assert [updated_media_item] = FileSyncing.sync_file_presence_on_disk([media_item])
      assert updated_media_item.media_filepath
    end

    test "doesn't touch other attributes if some are missing and some aren't" do
      media_item = media_item_with_attachments()
      File.rm(media_item.media_filepath)

      assert media_item.thumbnail_filepath
      assert media_item.media_filepath
      assert [updated_media_item] = FileSyncing.sync_file_presence_on_disk([media_item])
      assert updated_media_item.thumbnail_filepath
      refute updated_media_item.media_filepath
    end

    test "removes subtitle files that are missing" do
      media_item = media_item_fixture(%{subtitle_filepaths: [["en", "/tmp/missing_file.srt"]]})

      assert get_subtitle_filepath(media_item, "en")
      assert [updated_media_item] = FileSyncing.sync_file_presence_on_disk([media_item])
      refute get_subtitle_filepath(updated_media_item, "en")
    end

    test "doesn't remove subtitle files that still exist" do
      media_item = media_item_with_attachments()

      assert get_subtitle_filepath(media_item, "en")
      assert [updated_media_item] = FileSyncing.sync_file_presence_on_disk([media_item])
      assert get_subtitle_filepath(updated_media_item, "en")
    end

    # Subtitles are stored sorted by language (see MetadataParser)
    test "keeps only the subtitle files that still exist, in order" do
      subtitle_directory = Path.join(Application.get_env(:pinchflat, :media_directory), "#{:rand.uniform(1_000_000)}")

      [de_filepath, en_filepath, es_filepath, fr_filepath] =
        Enum.map(~w(de en es fr), &Path.join(subtitle_directory, "media.#{&1}.srt"))

      # Every subtitle file but the Spanish one exists
      Enum.each([de_filepath, en_filepath, fr_filepath], &FilesystemUtils.write_p!(&1, "subtitle"))

      media_item =
        media_item_fixture(%{
          subtitle_filepaths: [["de", de_filepath], ["en", en_filepath], ["es", es_filepath], ["fr", fr_filepath]]
        })

      assert [updated_media_item] = FileSyncing.sync_file_presence_on_disk([media_item])
      assert updated_media_item.subtitle_filepaths == [["de", de_filepath], ["en", en_filepath], ["fr", fr_filepath]]
    end

    test "removes subtitle entries without a filepath" do
      media_item = media_item_with_attachments()
      en_filepath = get_subtitle_filepath(media_item, "en")
      {:ok, media_item} = Media.update_media_item(media_item, %{subtitle_filepaths: [["en", en_filepath], ["ja", nil]]})

      assert [updated_media_item] = FileSyncing.sync_file_presence_on_disk([media_item])
      assert updated_media_item.subtitle_filepaths == [["en", en_filepath]]
    end
  end

  defp get_subtitle_filepath(media_item, language) do
    Enum.reduce_while(media_item.subtitle_filepaths, nil, fn [lang, filepath], acc ->
      if lang == language do
        {:halt, filepath}
      else
        {:cont, acc}
      end
    end)
  end
end
