defmodule Pinchflat.Downloading.QualityOptionBuilder do
  @moduledoc """
  A standalone builder module for building quality-related options for yt-dlp to download media.

  Currently exclusively used in DownloadOptionBuilder since this logic is too complex to just
  place in the main module.
  """

  require Logger

  alias Pinchflat.Settings
  alias Pinchflat.Profiles.MediaProfile

  @doc """
  Builds the quality-related options for yt-dlp to download media based on the given media profile

  Includes things like container, preferred format/codec, and audio track options.
  """
  def build(%MediaProfile{preferred_resolution: :audio} = media_profile) do
    acodec = Settings.get!(:audio_codec_preference)

    [
      :extract_audio,
      format_sort: "+acodec:#{acodec}",
      audio_format: build_audio_format(media_profile),
      format: build_format_string(media_profile)
    ]
  end

  def build(%MediaProfile{preferred_resolution: resolution_atom, media_container: container} = media_profile) do
    vcodec = Settings.get!(:video_codec_preference)
    acodec = Settings.get!(:audio_codec_preference)
    {resolution_string, _} = resolution_atom |> Atom.to_string() |> Integer.parse()

    [
      # Since Plex doesn't support reading metadata from MKV
      remux_video: container || "mp4",
      format_sort: "res:#{resolution_string},+codec:#{vcodec}:#{acodec}",
      format: build_format_string(media_profile)
    ]
  end

  defp build_audio_format(%MediaProfile{media_container: nil}), do: "best"

  # A profile saved before its container was validated can have one that yt-dlp doesn't take
  # as an audio format (eg: "mp4", left from before it was made audio only). That fails every download
  defp build_audio_format(%MediaProfile{media_container: container} = media_profile) do
    if MediaProfile.valid_media_container?(:audio, container) do
      container
    else
      Logger.warning(
        "Using the best audio format for media profile ##{media_profile.id} since its " <>
          "media container (#{inspect(container)}) isn't an audio format yt-dlp takes"
      )

      "best"
    end
  end

  defp build_format_string(%MediaProfile{preferred_resolution: :audio, audio_track: audio_track}) do
    if audio_track do
      "bestaudio[#{build_format_modifier(audio_track)}]/bestaudio/best"
    else
      "bestaudio/best"
    end
  end

  defp build_format_string(%MediaProfile{audio_track: audio_track}) do
    if audio_track do
      "bestvideo+bestaudio[#{build_format_modifier(audio_track)}]/bestvideo*+bestaudio/best"
    else
      "bestvideo*+bestaudio/best"
    end
  end

  # Reminder to self: this conflicts with `--extractor-args "youtube:lang=<LANG>"`
  # since that will translate the format_notes as well, which means they may not match.
  # At least that's what happens now - worth a re-check if I have to come back to this
  defp build_format_modifier("original"), do: "format_note*=original"
  defp build_format_modifier("default"), do: "format_note*='(default)'"
  # This uses the carat to anchor the language to the beginning of the string
  # since that's what's needed to match `en` to `en-US` and `en-GB`, etc. The user
  # can always specify the full language code if they want.
  defp build_format_modifier(language_code), do: "language^=#{language_code}"
end
