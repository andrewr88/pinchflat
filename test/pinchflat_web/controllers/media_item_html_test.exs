defmodule PinchflatWeb.MediaItemHTMLTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Media.MediaItem
  alias PinchflatWeb.MediaItems.MediaItemHTML

  # {extension, media type, the preview's `<source>` type}
  @previews [
    {"mp4", :video, "video/mp4"},
    {"webm", :video, "video/webm"},
    {"mov", :video, nil},
    {"mkv", :video, nil},
    {"mp3", :audio, "audio/mpeg"},
    {"m4a", :audio, "audio/mp4"},
    {"opus", :audio, nil},
    {"ogg", :audio, "audio/ogg"},
    {"flac", :audio, "audio/flac"},
    {"wav", :audio, "audio/wav"},
    {"aac", :audio, "audio/aac"},
    {"mka", :audio, nil},
    # Browsers don't play these
    {"flv", :unknown, nil},
    {"avi", :unknown, nil},
    {"aiff", :unknown, nil},
    {"gif", :unknown, nil},
    {"info.json", :unknown, nil}
  ]

  describe "media_type/1 and media_source_type/1" do
    test "classify media by its container" do
      for {extension, media_type, source_type} <- @previews do
        media_item = %MediaItem{media_filepath: "/media/My Video [abc123].#{extension}"}

        assert {extension, MediaItemHTML.media_type(media_item), MediaItemHTML.media_source_type(media_item)} ==
                 {extension, media_type, source_type}
      end
    end

    test "ignore the extension's case" do
      for {extension, media_type, source_type} <- @previews do
        media_item = %MediaItem{media_filepath: "/media/My Video [abc123].#{String.upcase(extension)}"}

        assert {extension, MediaItemHTML.media_type(media_item), MediaItemHTML.media_source_type(media_item)} ==
                 {extension, media_type, source_type}
      end
    end

    test "treat a file without an extension as unknown" do
      media_item = %MediaItem{media_filepath: "/media/My Video"}

      assert MediaItemHTML.media_type(media_item) == :unknown
      assert MediaItemHTML.media_source_type(media_item) == nil
    end
  end
end
