defmodule Pinchflat.Podcasts.PodcastHelpers do
  @moduledoc """
  Methods for fetching postcast-related data from a source
  or its media items
  """

  use Pinchflat.Media.MediaQuery
  use Pinchflat.Sources.SourcesQuery

  alias Pinchflat.Repo
  alias Pinchflat.Metadata.MediaMetadata
  alias Pinchflat.Metadata.SourceMetadata

  # The most media items a podcast feed includes
  @default_limit 2_000

  @doc """
  Returns a list of sources that are not being deleted: neither they nor their
  media profile (whose deletion deletes them too) are marked for deletion.

  Returns: [%Source{}]
  """
  def opml_sources() do
    SourcesQuery.new()
    |> join(:inner, [s], mp in assoc(s, :media_profile))
    |> select([s], %{custom_name: s.custom_name, uuid: s.uuid})
    |> where([s, mp], is_nil(s.marked_for_deletion_at) and is_nil(mp.marked_for_deletion_at))
    |> order_by(asc: :custom_name)
    |> Repo.all()
  end

  @doc """
  Returns a list of media items that have been downloaded to disk
  and have been proven to still exist there.

  Useful for podcasts since we don't want to serve media that
  has been deleted or moved, but it's also fairly generally useful
  so I could see this being moved in the future.

  Ordered newest first, with ties broken by ID so the order is the same every time.

  Options:
    - limit: integer - the maximum number of media items to return. Defaults to 2,000

  Returns: [%MediaItem{}]
  """
  def persisted_media_items_for(source, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    MediaQuery.new()
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded()))
    |> order_by(desc: :uploaded_at, desc: :id)
    |> stream_in_batches(limit)
    |> Stream.filter(&File.exists?(&1.media_filepath))
    |> Enum.take(limit)
  end

  @doc """
  Selects an episode image for a media item, ensuring it exists on disk.

  Returns: {:ok, filepath} | {:error, :no_suitable_image}
  """
  def select_episode_image(media_item) do
    filepath = media_item.thumbnail_filepath

    if filepath && File.exists?(filepath) do
      {:ok, filepath}
    else
      {:error, :no_suitable_image}
    end
  end

  @doc """
  Selects a cover image for a source based on the source's metadata
  and the metadata of the media items associated with the source. Also
  ensures images exist on disk.

  Only one media item should need to be returned since this is using the
  internal metadata which, so long as the media_item was _downloaded_, should
  be guaranteed to exist.

  Prefers the source's poster, then fanart, then the media item's thumbnail.

  Returns: {:ok, filepath} | {:error, :no_suitable_image}
  """
  def select_cover_image(source, media_items) do
    source_with_preloads = Repo.preload(source, :metadata)

    source_with_preloads
    |> get_images_by_preference(media_items)
    |> Enum.reject(&is_nil(&1))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> {:error, :no_suitable_image}
      filepath -> {:ok, filepath}
    end
  end

  defp get_images_by_preference(source_with_preloads, []) do
    source_metadata = source_with_preloads.metadata || %SourceMetadata{}

    [
      source_metadata.poster_filepath,
      source_metadata.fanart_filepath
    ]
  end

  defp get_images_by_preference(source_with_preloads, [media_item | _]) do
    media_item_with_preloads = Repo.preload(media_item, :metadata)
    media_item_metadata = media_item_with_preloads.metadata || %MediaMetadata{}
    source_images = get_images_by_preference(source_with_preloads, [])

    source_images ++ [media_item_metadata.thumbnail_filepath]
  end

  # Runs the query lazily, a batch at a time, so batches are only fetched while the caller is
  # still taking items. Here, that's until there are enough media items whose files exist
  defp stream_in_batches(query, batch_size) do
    Stream.unfold(0, fn batch_offset ->
      case query |> limit(^batch_size) |> offset(^batch_offset) |> Repo.all() do
        [] -> nil
        batch -> {batch, batch_offset + batch_size}
      end
    end)
    |> Stream.concat()
  end
end
