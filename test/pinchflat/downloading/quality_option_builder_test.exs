defmodule Pinchflat.Downloading.QualityOptionBuilderTest do
  use Pinchflat.DataCase
  import ExUnit.CaptureLog
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Profiles
  alias Pinchflat.Settings
  alias Pinchflat.Downloading.QualityOptionBuilder

  describe "build/1" do
    test "includes format options if audio_track is set to original" do
      media_profile = media_profile_fixture(%{audio_track: "original"})

      assert res = QualityOptionBuilder.build(media_profile)

      assert {:format, "bestvideo+bestaudio[format_note*=original]/bestvideo*+bestaudio/best"} in res
    end

    test "includes format options if audio_track is set to default" do
      media_profile = media_profile_fixture(%{audio_track: "default"})

      assert res = QualityOptionBuilder.build(media_profile)

      assert {:format, "bestvideo+bestaudio[format_note*='(default)']/bestvideo*+bestaudio/best"} in res
    end

    test "includes format options if audio_track is set to a language code" do
      media_profile = media_profile_fixture(%{audio_track: "en"})

      assert res = QualityOptionBuilder.build(media_profile)

      assert {:format, "bestvideo+bestaudio[language^=en]/bestvideo*+bestaudio/best"} in res
    end
  end

  describe "build/1 when testing audio profiles" do
    setup do
      {:ok, media_profile: media_profile_fixture(%{preferred_resolution: :audio})}
    end

    test "includes quality options for audio only", %{media_profile: media_profile} do
      assert res = QualityOptionBuilder.build(media_profile)

      assert :extract_audio in res
      assert {:format_sort, "+acodec:m4a"} in res

      refute {:remux_video, "mp4"} in res
    end

    test "includes custom format target for audio if specified", %{media_profile: media_profile} do
      {:ok, media_profile} =
        Profiles.update_media_profile(media_profile, %{media_container: "flac", preferred_resolution: :audio})

      assert res = QualityOptionBuilder.build(media_profile)

      assert {:audio_format, "flac"} in res
    end

    test "includes custom format options", %{media_profile: media_profile} do
      assert res = QualityOptionBuilder.build(media_profile)

      assert {:format, "bestaudio/best"} in res
    end

    test "uses an audio format container as is", %{media_profile: media_profile} do
      for container <- ["best", "aac", "m4a", "mp3", "opus", "wav", "webm>opus/mp3"] do
        res = QualityOptionBuilder.build(%{media_profile | media_container: container})

        assert {:audio_format, container} in res
      end
    end
  end

  # Profiles saved before the container was validated can have one that yt-dlp rejects
  # as an audio format, which fails every download
  describe "build/1 when an audio profile has a container that isn't an audio format" do
    setup do
      Logger.put_module_level(QualityOptionBuilder, :all)
      on_exit(fn -> Logger.delete_module_level(QualityOptionBuilder) end)

      {:ok, media_profile: media_profile_fixture(%{preferred_resolution: :audio})}
    end

    test "uses the best audio format and logs a warning", %{media_profile: media_profile} do
      for container <- ["mp4", "mkv", "webm", "ogg", "MP3", " mp3", "m4a>mp4", "foo"] do
        log =
          capture_log(fn ->
            res = QualityOptionBuilder.build(%{media_profile | media_container: container})

            assert {:audio_format, "best"} in res
          end)

        assert log =~ "[warning]"
        assert log =~ "media profile ##{media_profile.id}"
        assert log =~ inspect(container)
      end
    end
  end

  describe "build/1 when testing non-audio profiles" do
    setup do
      {:ok, media_profile: media_profile_fixture(%{preferred_resolution: :"480p"})}
    end

    test "includes quality options" do
      resolutions = ["360", "480", "720", "1080", "1440", "2160", "4320"]

      Enum.each(resolutions, fn resolution ->
        resolution_atom = String.to_existing_atom(resolution <> "p")
        media_profile = media_profile_fixture(%{preferred_resolution: resolution_atom})

        assert res = QualityOptionBuilder.build(media_profile)

        assert {:format_sort, "res:#{resolution},+codec:avc:m4a"} in res
        assert {:remux_video, "mp4"} in res
      end)
    end

    test "includes custom quality options if specified", %{media_profile: media_profile} do
      Settings.set(video_codec_preference: "av01")
      Settings.set(audio_codec_preference: "aac")

      {:ok, media_profile} = Profiles.update_media_profile(media_profile, %{preferred_resolution: :"1080p"})

      assert res = QualityOptionBuilder.build(media_profile)

      assert {:format_sort, "res:1080,+codec:av01:aac"} in res
    end

    test "includes custom remux target for videos if specified", %{media_profile: media_profile} do
      {:ok, media_profile} = Profiles.update_media_profile(media_profile, %{media_container: "mkv"})

      assert res = QualityOptionBuilder.build(media_profile)

      assert {:remux_video, "mkv"} in res
    end

    test "includes custom format options", %{media_profile: media_profile} do
      assert res = QualityOptionBuilder.build(media_profile)

      assert {:format, "bestvideo*+bestaudio/best"} in res
    end
  end
end
