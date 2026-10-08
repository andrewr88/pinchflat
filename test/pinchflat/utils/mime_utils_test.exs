defmodule Pinchflat.Utils.MimeUtilsTest do
  use Pinchflat.DataCase

  alias Pinchflat.Utils.MimeUtils

  describe "from_path/1" do
    test "returns the type of each media container yt-dlp can produce" do
      # yt-dlp names `--audio-format` alac files .m4a and vorbis files .ogg
      types = %{
        "aac" => "audio/aac",
        "aiff" => "audio/aiff",
        "avi" => "video/x-msvideo",
        "flac" => "audio/flac",
        "flv" => "video/x-flv",
        "gif" => "image/gif",
        "m4a" => "audio/mp4",
        "mka" => "audio/x-matroska",
        "mkv" => "video/x-matroska",
        "mov" => "video/quicktime",
        "mp3" => "audio/mpeg",
        "mp4" => "video/mp4",
        "ogg" => "audio/ogg",
        "opus" => "audio/opus",
        "wav" => "audio/wav",
        "webm" => "video/webm"
      }

      for {extension, type} <- types do
        assert {extension, MimeUtils.from_path("/downloads/My Video [abc123].#{extension}")} == {extension, type}
      end
    end

    test "ignores the case of the extension" do
      assert MimeUtils.from_path("/downloads/song.M4A") == "audio/mp4"
    end

    test "falls back to MIME's type for other files" do
      assert MimeUtils.from_path("/downloads/thumbnail.jpg") == "image/jpeg"
      assert MimeUtils.from_path("/downloads/no_extension") == "application/octet-stream"
    end
  end
end
