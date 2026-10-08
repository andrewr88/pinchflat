defmodule PinchflatWeb.MediaItems.MediaItemHTML do
  use PinchflatWeb, :html

  alias Pinchflat.Utils.MimeUtils

  embed_templates "media_item_html/*"

  # The containers the preview tries to play, by MIME type. Not every browser plays Matroska (mkv/mka)
  # or QuickTime (mov) files, but those that can't just don't play the preview
  @video_types ~w(video/mp4 video/webm video/quicktime video/x-matroska)
  @audio_types ~w(audio/mpeg audio/mp4 audio/ogg audio/opus audio/flac audio/wav audio/aac audio/x-matroska)
  # A browser skips a `<source>` whose type it doesn't recognize, even if it could play the file, and which
  # Matroska, QuickTime and Opus types are recognized varies. So the preview's type is only set to these
  # standard ones and is otherwise left off for the browser to work out from the file itself
  @source_types ~w(video/mp4 video/webm audio/mpeg audio/mp4 audio/ogg audio/flac audio/wav audio/aac)

  @doc """
  Renders a media item form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true

  def media_item_form(assigns)

  def media_file_exists?(media_item) do
    !!media_item.media_filepath and File.exists?(media_item.media_filepath)
  end

  @doc """
  Returns how a media item's file is previewed.

  Returns :video | :audio | :unknown
  """
  def media_type(media_item) do
    mime_type = MimeUtils.from_path(media_item.media_filepath)

    cond do
      mime_type in @video_types -> :video
      mime_type in @audio_types -> :audio
      true -> :unknown
    end
  end

  @doc """
  Returns the type for a media item's preview `<source>`, if it should have one.

  Returns binary() | nil
  """
  def media_source_type(media_item) do
    mime_type = MimeUtils.from_path(media_item.media_filepath)

    if mime_type in @source_types, do: mime_type
  end
end
