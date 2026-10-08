defmodule Pinchflat.ProfilesTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Profiles
  alias Pinchflat.Profiles.MediaProfile

  @valid_attrs %{name: "some name", output_path_template: "output_template.{{ ext }}"}
  @invalid_attrs %{name: nil, output_path_template: nil}

  describe "schema" do
    test "can be JSON encoded without error" do
      profile = media_profile_fixture()

      assert {:ok, _} = Phoenix.json_library().encode(profile)
    end
  end

  describe "list_media_profiles/0" do
    test "it returns all media_profiles" do
      media_profile = media_profile_fixture()
      assert Profiles.list_media_profiles() == [media_profile]
    end
  end

  describe "get_media_profile!/1" do
    test "it returns the media_profile with given id" do
      media_profile = media_profile_fixture()
      assert Profiles.get_media_profile!(media_profile.id) == media_profile
    end
  end

  describe "create_media_profile/1" do
    test "creation with valid data creates a media_profile" do
      valid_attrs = %{name: "some name", output_path_template: "output_template.{{ ext }}"}

      assert {:ok, %MediaProfile{} = media_profile} = Profiles.create_media_profile(valid_attrs)
      assert media_profile.name == "some name"
      assert media_profile.output_path_template == "output_template.{{ ext }}"
    end

    test "creation with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Profiles.create_media_profile(@invalid_attrs)
    end
  end

  describe "update_media_profile/2" do
    test "updating with valid data updates the media_profile" do
      media_profile = media_profile_fixture()

      update_attrs = %{
        name: "some updated name",
        output_path_template: "new_output_template.{{ ext }}"
      }

      assert {:ok, %MediaProfile{} = media_profile} =
               Profiles.update_media_profile(media_profile, update_attrs)

      assert media_profile.name == "some updated name"
      assert media_profile.output_path_template == "new_output_template.{{ ext }}"
    end

    test "updating with invalid data returns error changeset" do
      media_profile = media_profile_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Profiles.update_media_profile(media_profile, @invalid_attrs)

      assert media_profile == Profiles.get_media_profile!(media_profile.id)
    end
  end

  describe "delete_media_profile/2" do
    test "deletion deletes the media_profile" do
      media_profile = media_profile_fixture()

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_profile) end
    end

    test "deletion deletes all sources" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(source) end
    end

    test "deletion deletes all media items" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)
      media_item = media_item_fixture(source_id: source.id)

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_item) end
    end

    test "deletion does not delete files by default" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)
      media_item = media_item_with_attachments(%{source_id: source.id})

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile)

      assert File.exists?(media_item.media_filepath)
    end
  end

  describe "delete_media_profile/2 when deleting files" do
    setup do
      stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

      :ok
    end

    test "still deletes all the needful records" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)
      media_item = media_item_fixture(source_id: source.id)

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile, delete_files: true)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_profile) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(source) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_item) end
    end

    test "deletes files" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)
      media_item = media_item_with_attachments(%{source_id: source.id})

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile, delete_files: true)

      refute File.exists?(media_item.media_filepath)
    end

    # eg: a source being created on the profile is saved after its sources were listed
    test "returns an error if a source is added to the profile while it's being deleted" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)
      media_item_with_attachments(%{source_id: source.id})
      # Runs while the existing source's media is being deleted
      expect(UserScriptRunnerMock, :run, fn :media_deleted, _ -> source_fixture(media_profile_id: media_profile.id) end)

      assert {:error, %Ecto.Changeset{} = changeset} = Profiles.delete_media_profile(media_profile, delete_files: true)

      assert "are still associated with this entry" in errors_on(changeset).sources
      assert Repo.reload!(media_profile)
    end
  end

  describe "change_media_profile/1" do
    test "it returns a media_profile changeset" do
      media_profile = media_profile_fixture()
      assert %Ecto.Changeset{} = Profiles.change_media_profile(media_profile)
    end

    test "it ensures the media profile's output template ends with an extension" do
      valid_templates = [
        "output_template.{{ ext }}",
        "output_template.{{ext}}",
        "output_template.%(ext)s",
        "output_template.%(ext)S",
        "output_template.%( ext )s",
        "output_template.%( ext )S"
      ]

      for template <- valid_templates do
        cs = Profiles.change_media_profile(%MediaProfile{}, %{name: "a", output_path_template: template})

        assert cs.valid?
      end
    end

    test "it does not allow invalid output templates" do
      invalid_templates = [
        "output_template.{{ ext }}.something",
        "output_template.{{   ext   }}",
        "output_template{{ ext }}",
        "output_template.%(ext)s.something",
        "output_template.txt",
        "output_template%(ext)s",
        "output_template.%(nope)s",
        "output_template"
      ]

      for template <- invalid_templates do
        cs = Profiles.change_media_profile(%MediaProfile{}, %{name: "a", output_path_template: template})

        refute cs.valid?
      end
    end
  end

  describe "change_media_profile/2 when testing media container validation" do
    # Audio only profiles pass it to yt-dlp's `--audio-format`, others to `--remux-video`
    test "allows the containers yt-dlp accepts for the profile's resolution" do
      valid_containers = [
        {:audio, nil},
        {:audio, "best"},
        {:audio, "m4a"},
        {:audio, "mp3"},
        {:audio, "opus"},
        {:audio, "flac"},
        {:audio, "webm>opus/mp3"},
        {:"1080p", nil},
        {:"1080p", "mp4"},
        {:"1080p", "mkv"},
        {:"1080p", "webm"},
        {:"1080p", "mp3"},
        {:"720p", "webm>mkv/mp4"},
        {:"720p", "aac>m4a/mov>mp4/mkv"}
      ]

      for {resolution, container} <- valid_containers do
        attrs = %{preferred_resolution: resolution, media_container: container}
        cs = Profiles.change_media_profile(%MediaProfile{}, Map.merge(@valid_attrs, attrs))

        assert cs.valid?, "expected #{inspect(container)} to be valid for #{resolution}"
      end
    end

    test "rejects containers yt-dlp doesn't accept for the profile's resolution" do
      invalid_containers = [
        {:audio, "mp4"},
        {:audio, "mkv"},
        {:audio, "webm"},
        {:audio, "ogg"},
        {:audio, "MP3"},
        {:audio, " mp3"},
        {:audio, "m4a>mp4"},
        {:"1080p", "best"},
        {:"1080p", "foo"},
        {:"1080p", "MP4"},
        {:"1080p", "mp4 "},
        {:"1080p", "mp4/"},
        {:"1080p", ">mp4"},
        {:"1080p", "webm>foo"},
        {:"1080p", "web-m>mp4"},
        {:"1080p", "mp4\n"},
        {:"1080p", "mp4 --exec rm"}
      ]

      for {resolution, container} <- invalid_containers do
        attrs = %{preferred_resolution: resolution, media_container: container}
        cs = Profiles.change_media_profile(%MediaProfile{}, Map.merge(@valid_attrs, attrs))

        refute cs.valid?, "expected #{inspect(container)} to be invalid for #{resolution}"
        assert [_] = errors_on(cs).media_container
      end
    end

    test "treats a blank container as the default" do
      cs = Profiles.change_media_profile(%MediaProfile{}, Map.put(@valid_attrs, :media_container, "  "))

      assert cs.valid?
      assert get_field(cs, :media_container) == nil
    end

    test "checks the stored container when the resolution changes" do
      media_profile = media_profile_fixture(preferred_resolution: :"1080p", media_container: "mp4")

      cs = Profiles.change_media_profile(media_profile, %{preferred_resolution: :audio})

      assert errors_on(cs).media_container == [
               "must be one of best, aac, alac, flac, m4a, mp3, opus, vorbis, wav for audio only"
             ]
    end

    test "checks the stored resolution when the container changes" do
      media_profile = media_profile_fixture(preferred_resolution: :audio)

      cs = Profiles.change_media_profile(media_profile, %{media_container: "mp4"})

      refute cs.valid?
    end

    # eg: a profile saved before containers were checked can still be marked for deletion
    test "doesn't check a stored container when neither it nor the resolution changes" do
      media_profile = media_profile_fixture(preferred_resolution: :audio)
      {:ok, media_profile} = Repo.update(change(media_profile, media_container: "mp4"))

      assert {:ok, _} = Profiles.update_media_profile(media_profile, %{marked_for_deletion_at: now()})
    end
  end

  describe "change_media_profile/2 when testing audio track validation" do
    test "allows a language code, original or default" do
      for audio_track <- [nil, "original", "default", "de", "en", "EN", "yue", "en-US", "pt-BR", "zh-Hans", "es-419"] do
        cs = Profiles.change_media_profile(%MediaProfile{}, Map.put(@valid_attrs, :audio_track, audio_track))

        assert cs.valid?, "expected #{inspect(audio_track)} to be valid"
      end
    end

    # It's put into a yt-dlp format filter, eg: `bestaudio[language^=de]`
    test "rejects anything else" do
      invalid_audio_tracks = [
        "d",
        "deutsch",
        "Original",
        "en_US",
        "en-",
        "-en",
        "en-US!",
        "de\n",
        "de]/worst[",
        "de]+bestvideo"
      ]

      for audio_track <- invalid_audio_tracks do
        cs = Profiles.change_media_profile(%MediaProfile{}, Map.put(@valid_attrs, :audio_track, audio_track))

        refute cs.valid?, "expected #{inspect(audio_track)} to be invalid"
        assert [_] = errors_on(cs).audio_track
      end
    end

    test "treats a blank audio track as unset" do
      cs = Profiles.change_media_profile(%MediaProfile{}, Map.put(@valid_attrs, :audio_track, " "))

      assert cs.valid?
      assert get_field(cs, :audio_track) == nil
    end
  end
end
