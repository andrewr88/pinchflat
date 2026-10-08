defmodule Pinchflat.Utils.MimeUtils do
  @moduledoc """
  Utility methods for working with MIME types
  """

  # Media containers that yt-dlp can produce but MIME doesn't know, so it'd return
  # application/octet-stream for them (which podcast clients reject). yt-dlp names
  # `--audio-format` alac files .m4a and vorbis files .ogg so those don't need entries
  @media_types %{
    "aiff" => "audio/aiff",
    "flac" => "audio/flac",
    "flv" => "video/x-flv",
    "m4a" => "audio/mp4",
    "mka" => "audio/x-matroska",
    "mkv" => "video/x-matroska",
    "ogg" => "audio/ogg"
  }

  @doc """
  Returns the MIME type of a file based on its extension. Like `MIME.from_path/1`
  but it also knows the types of all the media containers yt-dlp can produce.

  Returns binary()
  """
  def from_path(filepath) do
    extension =
      filepath
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.downcase()

    Map.get_lazy(@media_types, extension, fn -> MIME.from_path(filepath) end)
  end
end
