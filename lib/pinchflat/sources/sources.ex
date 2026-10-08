defmodule Pinchflat.Sources do
  @moduledoc """
  The Sources context.
  """

  import Ecto.Query, warn: false
  use Pinchflat.Media.MediaQuery

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Tasks
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Utils.StringUtils
  alias Pinchflat.YtDlp.MediaCollection
  alias Pinchflat.Metadata.SourceMetadata
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.FastIndexing.FastIndexingHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  @doc """
  Returns the relevant output path template for a source.
  Pulls from the source's override if present, otherwise uses the media profile's.

  Returns binary()
  """
  def output_path_template(source) do
    source = Repo.preload(source, :media_profile)
    media_profile = source.media_profile

    source.output_path_template_override || media_profile.output_path_template
  end

  @doc """
  Returns a boolean indicating whether or not cookies should be used for a given operation.

  Returns boolean()
  """
  def use_cookies?(source, operation) when operation in [:indexing, :downloading, :metadata, :error_recovery] do
    case source.cookie_behaviour do
      :disabled -> false
      :all_operations -> true
      :when_needed -> operation in [:indexing, :error_recovery]
    end
  end

  @doc """
  Returns the list of sources. Returns [%Source{}, ...]
  """
  def list_sources do
    Repo.all(Source)
  end

  @doc """
  Returns the list of sources for a media_profile.

  Returns [%Source{}, ...]
  """
  def list_sources_for(%MediaProfile{} = media_profile) do
    Repo.all(from s in Source, where: s.media_profile_id == ^media_profile.id)
  end

  @doc """
  Gets a single source.

  Returns %Source{}. Raises `Ecto.NoResultsError` if the Source does not exist.
  """
  def get_source!(id), do: Repo.get!(Source, id)

  @doc """
  Gets a single source that isn't being deleted: neither it nor its media profile (whose
  deletion deletes it too) is marked for deletion. Those are hidden everywhere else, so a
  source that's being deleted is treated like one that's already gone.

  Returns %Source{}. Raises `Ecto.NoResultsError` if the Source does not exist or is being deleted.
  """
  def get_source_not_being_deleted!(id) do
    query =
      from s in Source,
        inner_join: mp in assoc(s, :media_profile),
        where: is_nil(s.marked_for_deletion_at) and is_nil(mp.marked_for_deletion_at)

    Repo.get!(query, id)
  end

  @doc """
  Creates a source. May attempt to pull additional source details from the
  original_url (if provided). Will attempt to start indexing the source's
  media if successfully inserted and enabled.

  Runs an initial `change_source` check to ensure most of the source is valid
  before making an expensive API call. Runs it through `Repo.insert` even
  though we know it's going to fail so it picks up any addl. database errors
  and fulfills our return contract.

  You can pass options to control the behavior of the function:
    - `run_post_commit_tasks` (default: true) - If false, the function will not
      enqueue any tasks in `commit_and_handle_tasks`.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def create_source(attrs, opts \\ []) do
    case change_source(%Source{}, attrs, :initial) do
      %Ecto.Changeset{valid?: true} ->
        %Source{}
        |> maybe_change_source_from_url(attrs)
        |> maybe_change_indexing_frequency()
        |> commit_and_handle_tasks(opts)

      changeset ->
        Repo.insert(changeset)
    end
  end

  @doc """
  Updates a source. May attempt to pull additional source details from the
  original_url (if changed). May attempt to start indexing the source's
  media if the indexing frequency has been changed.

  Existing indexing tasks will be cancelled if the indexing frequency has been
  changed (logic in `SlowIndexingHelpers.kickoff_indexing_task`)

  Runs an initial `change_source` check to ensure most of the source is valid
  before making an expensive API call. Runs it through `Repo.update` even
  though we know it's going to fail so it picks up any addl. database errors
  and fulfills our return contract.

  You can pass options to control the behavior of the function:
    - `run_post_commit_tasks` (default: true) - If false, the function will not
      enqueue any tasks in `commit_and_handle_tasks`.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def update_source(%Source{} = source, attrs, opts \\ []) do
    case change_source(source, attrs, :initial) do
      %Ecto.Changeset{valid?: true} ->
        source
        |> maybe_change_source_from_url(attrs)
        |> maybe_change_indexing_frequency()
        |> commit_and_handle_tasks(opts)

      changeset ->
        Repo.update(changeset)
    end
  end

  @doc """
  Deletes a source, its media items, and its associated tasks (of any state).
  Can optionally delete the source's media files.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_source(%Source{} = source, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)
    Tasks.delete_tasks_for(source)

    media_items =
      MediaQuery.new()
      |> where(^MediaQuery.for_source(source))
      |> Repo.all()

    # A download that finishes after the media items are loaded writes paths their loaded copies
    # don't have, which would leave its files behind. So the downloads are stopped before anything
    # is deleted, and each media item is reloaded before it's deleted
    Enum.each(media_items, &Tasks.delete_tasks_for/1)

    Enum.each(media_items, fn media_item ->
      case Repo.reload(media_item) do
        nil -> :ok
        reloaded_media_item -> Media.delete_media_item(reloaded_media_item, delete_files: delete_files)
      end
    end)

    if delete_files do
      delete_source_files(source)
    end

    delete_internal_metadata_files(source)
    Repo.delete(source)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking source changes.
  """
  def change_source(%Source{} = source, attrs \\ %{}, validation_stage \\ :pre_insert) do
    Source.changeset(source, attrs, validation_stage)
  end

  @doc """
  Checks if a source other than the given one uses the file at `filepath` as its NFO or one of
  its images. Sources for the same channel (e.g. with different title filters) can share a
  series directory, and so these files.

  Returns boolean()
  """
  def file_used_by_another_source?(filepath, %Source{} = source) do
    Source
    |> where([s], s.id != ^source.id)
    |> where(
      [s],
      s.nfo_filepath == ^filepath or s.poster_filepath == ^filepath or
        s.fanart_filepath == ^filepath or s.banner_filepath == ^filepath
    )
    |> Repo.exists?()
  end

  @doc """
  Moves a source's files to match its current custom_name and output path template,
  then updates the stored paths. This will:
  1. Rebuild the series_directory with a yt-dlp lookup. If the lookup fails, return an
     error before any file or database change. If the output template has no season
     folder (e.g. the default template) there is no series_directory, so the source's
     own fields and files are left alone and only the media items are moved
  2. Work out the new source paths: series_directory, plus the nfo_filepath and
     poster/fanart/banner paths the source has. Source metadata images live in the
     internal metadata directory and aren't moved
  3. For each downloaded media item, work out the new media path: the filename yt-dlp
     gives the item with the current output template, worked out offline from the item's
     stored info JSON, keeping the extension of the current media file. The subtitle,
     thumbnail, NFO, `.info.json` and predicted media paths follow the new media path (the
     stored info JSON, in the internal metadata directory, doesn't move). An item whose
     new path can't be worked out (no stored info JSON, or yt-dlp fails) or would be
     outside the media directory keeps its current paths. This is logged and the other
     files are still moved.
     Filename options in the user's yt-dlp config files (e.g. `--trim-filenames`, `-P`) aren't applied to the new paths
  4. Move each file by copying it, verifying the copy, then deleting the original.
     Files move whatever the media profile's download options are now: they may have
     been downloaded before an option was turned off.
     A move never overwrites an existing file. Files that don't exist are skipped,
     but their paths are still updated. A file whose new path is already the same file
     (e.g. only the case changes, on a case-insensitive filesystem) is renamed instead
  5. Update all path fields in one database transaction

  If a move or the database update fails, the moves already made are undone in reverse
  order (also copy-verify-delete) and nothing is written to the database, so files and
  database are left as they were (directories created for the moves are left, empty).
  A file that can't be moved back is logged and named in the error.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}. The changeset's error is on
  `:series_directory` if the yt-dlp lookup failed, otherwise on `:file_operations`.
  """
  def update_source_directory(%Source{} = source) do
    source = Repo.preload(source, [:media_profile, :metadata])

    # Step 1: Rebuild series_directory (outside transaction to avoid timeout)
    case rebuild_series_directory(source) do
      {:ok, new_series_directory} ->
        move_files_and_update_paths(source, new_series_directory)

      # Normal for output templates with no season folder: there's no series directory
      {:error, :indeterminable} ->
        move_files_and_update_paths(source, nil)

      # Nothing has been moved or written yet, so there's nothing to undo
      {:error, :lookup_failed} ->
        update_directory_error(source, :series_directory, "could not determine the new series directory")
    end
  end

  defp move_files_and_update_paths(source, new_series_directory) do
    with {:ok, source_updates, media_item_updates, moves} <- plan_moves(source, new_series_directory) do
      # Step 4: Move all files (outside transaction to avoid timeout)
      # This is the slow part, so we do it before the transaction
      case move_files(moves) do
        {:ok, completed_moves} ->
          # Step 5: Update database in transaction (fast, no file I/O)
          case update_paths_in_database(source, source_updates, media_item_updates) do
            {:ok, updated_source} ->
              {:ok, updated_source}

            {:error, reason} ->
              rollback_and_return_error(source, completed_moves, "Database update failed: #{inspect(reason)}")
          end

        {:error, reason, completed_moves} ->
          rollback_and_return_error(source, completed_moves, "File operations failed: #{reason}")
      end
    end
  end

  # Works out the new paths and the {old_path, new_path} moves they need.
  #
  # Returns {:ok, source_updates, media_item_updates, moves} | {:error, %Ecto.Changeset{}}
  defp plan_moves(source, new_series_directory) do
    # Step 2: Prepare the source's updates. Its own fields and files only change when there's
    # a new series directory - without one (no season folder in the template) they're left alone
    {source_updates, source_moves} =
      if new_series_directory && source.series_directory != new_series_directory do
        source_updates = build_source_path_updates(source, new_series_directory)
        {source_updates, source_file_moves(source, source_updates)}
      else
        {%{}, []}
      end

    # Step 3: Get all media items and prepare their updates
    media_items = get_all_media_items_for_source(source)
    media_item_updates = prepare_media_item_updates(media_items)

    media_item_moves =
      Enum.flat_map(media_item_updates, fn {media_item, new_paths} ->
        media_item_file_moves(media_item, new_paths)
      end)

    {:ok, source_updates, media_item_updates, source_moves ++ media_item_moves}
  rescue
    # Nothing has been moved yet. Keep this rescue here: once files have moved, a raise
    # must not turn into an error that skips the rollback
    error -> update_directory_error(source, :file_operations, "Could not work out the new paths: #{inspect(error)}")
  end

  defp update_paths_in_database(source, source_updates, media_item_updates) do
    Repo.transaction(fn ->
      {:ok, updated_source} = update_source(source, source_updates, run_post_commit_tasks: false)

      # Update all media items
      Enum.each(media_item_updates, fn {media_item, updates} ->
        {:ok, _} = Media.update_media_item(media_item, updates)
      end)

      updated_source
    end)
  rescue
    # A raise inside the transaction (e.g. a failed `{:ok, _} =` match) has already rolled it back.
    # Treat it the same as the transaction returning an error
    error -> {:error, error}
  end

  # Undoes the completed moves, then returns the error. Files that couldn't be
  # moved back are named in the error so they can be fixed by hand
  defp rollback_and_return_error(source, completed_moves, message) do
    case rollback_moves(completed_moves) do
      [] ->
        update_directory_error(source, :file_operations, message)

      failed_rollbacks ->
        not_moved_back =
          Enum.map_join(failed_rollbacks, ", ", fn {old_path, new_path, reason} ->
            "#{new_path} -> #{old_path} (#{inspect(reason)})"
          end)

        update_directory_error(
          source,
          :file_operations,
          "#{message}. These files could not be moved back: #{not_moved_back}"
        )
    end
  end

  defp update_directory_error(source, field, message) do
    source
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(field, message)
    |> Ecto.Changeset.apply_action(:update)
  end

  # Returns {:ok, series_directory} | {:error, :indeterminable} | {:error, :lookup_failed}.
  # :indeterminable isn't a failure - it's what templates with no season folder give
  defp rebuild_series_directory(source) do
    output_path = DownloadOptionBuilder.build_output_path_for(source)
    runner_opts = [output: output_path]
    addl_opts = [use_cookies: use_cookies?(source, :metadata)]

    case MediaCollection.get_source_details(source.original_url, runner_opts, addl_opts) do
      {:ok, %{filepath: filepath}} when is_binary(filepath) ->
        MetadataFileHelpers.series_directory_from_media_filepath(filepath)

      _ ->
        {:error, :lookup_failed}
    end
  end

  # Only called when the series_directory changes. Existing images and NFO move whatever the
  # profile's download options are now: they may have been downloaded before one was turned off
  defp build_source_path_updates(source, new_series_directory) do
    # The images keep their filenames in the new series_directory
    image_updates =
      for {field, filepath} <- Map.take(source, [:poster_filepath, :fanart_filepath, :banner_filepath]),
          filepath,
          into: %{},
          do: {field, Path.join(new_series_directory, Path.basename(filepath))}

    nfo_updates =
      if source.nfo_filepath do
        %{nfo_filepath: Path.join(new_series_directory, "tvshow.nfo")}
      else
        %{}
      end

    %{series_directory: new_series_directory}
    |> Map.merge(image_updates)
    |> Map.merge(nfo_updates)
  end

  # Returns the {old_path, new_path} moves for the source's own files. The update map only
  # has a key when that path changes (e.g. not when the source has no banner), hence the
  # `map[:key]` access.
  #
  # Source metadata images aren't moved: SourceMetadataStorageWorker always stores them in
  # the internal metadata directory (`MetadataFileHelpers.metadata_directory_for/1`), which
  # doesn't depend on the series_directory
  defp source_file_moves(source, source_updates) do
    Enum.filter(
      [
        {source.poster_filepath, source_updates[:poster_filepath]},
        {source.fanart_filepath, source_updates[:fanart_filepath]},
        {source.banner_filepath, source_updates[:banner_filepath]},
        {source.nfo_filepath, source_updates[:nfo_filepath]}
      ],
      &file_needs_move?/1
    )
  end

  defp file_needs_move?({old_path, new_path}) do
    is_binary(old_path) and is_binary(new_path) and old_path != new_path and File.exists?(old_path)
  end

  defp prepare_media_item_updates(media_items) do
    Enum.map(media_items, fn media_item ->
      media_item = Repo.preload(media_item, [:metadata, source: :media_profile])

      # Rebuild media_filepath with yt-dlp using the current output template. Items with no
      # media file have nothing to move, so yt-dlp isn't run for them
      new_media_filepath = media_item.media_filepath && rebuild_media_filepath(media_item)

      # Only prepare updates if the path has actually changed. If the new path couldn't be
      # worked out (nil), the item keeps its current paths
      if new_media_filepath && media_item.media_filepath != new_media_filepath do
        # Build new paths based on new media_filepath
        new_paths = build_new_media_item_paths(media_item, new_media_filepath)
        {media_item, new_paths}
      else
        {media_item, nil}
      end
    end)
    |> Enum.filter(fn {_media_item, updates} -> updates != nil end)
  end

  # Returns the filename yt-dlp gives the media item with the current output template,
  # worked out offline from the item's stored info JSON. The extension of the current media
  # file is kept, since the info JSON's can differ from it (e.g. after a merge or remux).
  #
  # Returns binary() | nil. nil (logged) when there's no stored info JSON, yt-dlp fails, or the filename is
  # outside the media directory: yt-dlp fills in the template's fields from the media's metadata and writes
  # a field that's a whole folder of the template as-is, even if it's ".."
  defp rebuild_media_filepath(media_item) do
    output_template = DownloadOptionBuilder.build_output_path_for(media_item)
    # Passed like in a real download: they decide the format, which the filename can depend on
    quality_options = DownloadOptionBuilder.build_quality_options_for(media_item)

    with {:ok, info_json} <- read_stored_info_json(media_item),
         {:ok, filepath} <-
           YtDlpMedia.get_output_filepath(info_json, output_template, quality_options, skip_sleep_interval: true),
         :ok <- ensure_inside_media_directory(filepath) do
      Path.rootname(filepath) <> Path.extname(media_item.media_filepath)
    else
      error ->
        Logger.warning(
          "Media item ##{media_item.id} keeps its current paths: could not work out its new path: #{inspect(error)}"
        )

        nil
    end
  end

  # Returns {:ok, map()} | {:error, binary()}. Never raises, so a bad file only skips its media item
  # (read_compressed_metadata/1 raises if the file is missing, empty or not valid gzip)
  defp read_stored_info_json(%{metadata: %{metadata_filepath: filepath}}) when is_binary(filepath) do
    if File.regular?(filepath) do
      MetadataFileHelpers.read_compressed_metadata(filepath)
    else
      {:error, "stored info JSON #{filepath} doesn't exist"}
    end
  rescue
    error -> {:error, "could not read stored info JSON #{filepath}: #{Exception.message(error)}"}
  end

  defp read_stored_info_json(_media_item), do: {:error, "no stored info JSON"}

  defp ensure_inside_media_directory(filepath) do
    if FilesystemUtils.inside_directory?(filepath, Application.get_env(:pinchflat, :media_directory)) do
      :ok
    else
      {:error, "#{inspect(filepath)} is outside the media directory"}
    end
  end

  defp build_new_media_item_paths(media_item, new_media_filepath) do
    updates = %{media_filepath: new_media_filepath}

    # Rebuild subtitle_filepaths. yt-dlp names subtitles after the media file:
    # <media filepath without extension>.<lang>.<subtitle extension>
    updates =
      if media_item.subtitle_filepaths && media_item.subtitle_filepaths != [] do
        new_media_rootname = Path.rootname(new_media_filepath)

        new_subtitle_filepaths =
          Enum.map(media_item.subtitle_filepaths, fn
            [lang, old_subtitle_path] when is_binary(old_subtitle_path) ->
              [lang, "#{new_media_rootname}.#{lang}#{Path.extname(old_subtitle_path)}"]

            # No file was stored for this subtitle (e.g. a nil path), so there's nothing to rename
            subtitle ->
              subtitle
          end)

        Map.put(updates, :subtitle_filepaths, new_subtitle_filepaths)
      else
        updates
      end

    # Rebuild thumbnail_filepath if it moves with the media file. It's named after the media file but
    # keeps its own extension: <media filepath without extension>-thumb.<thumbnail extension>
    updates =
      if thumbnail_moves_with_media_file?(media_item) do
        new_thumbnail_filepath =
          Path.rootname(new_media_filepath) <> "-thumb" <> Path.extname(media_item.thumbnail_filepath)

        Map.put(updates, :thumbnail_filepath, new_thumbnail_filepath)
      else
        updates
      end

    # Rebuild nfo_filepath. Existing files move whatever the profile's download options are now:
    # they may have been downloaded before one was turned off
    updates =
      if media_item.nfo_filepath do
        new_nfo_filepath = Path.rootname(new_media_filepath) <> ".nfo"
        Map.put(updates, :nfo_filepath, new_nfo_filepath)
      else
        updates
      end

    # Rebuild metadata_filepath: the .info.json yt-dlp writes next to the media file, named after it.
    # Not the stored info JSON in the internal metadata directory (media_item.metadata), which doesn't move
    updates =
      if media_item.metadata_filepath do
        new_metadata_filepath = Path.rootname(new_media_filepath) <> ".info.json"
        Map.put(updates, :metadata_filepath, new_metadata_filepath)
      else
        updates
      end

    # Rebuild predicted_media_filepath
    updates =
      if media_item.predicted_media_filepath do
        Map.put(updates, :predicted_media_filepath, new_media_filepath)
      else
        updates
      end

    # Internal metadata files are stored in a metadata directory based on media_item.id,
    # so they don't need to move when the source directory changes
    # No updates needed for metadata association

    updates
  end

  # Returns the {old_path, new_path} moves for a media item's files
  defp media_item_file_moves(media_item, new_paths) do
    # Media file
    media_moves = [{media_item.media_filepath, new_paths[:media_filepath]}]

    # Subtitle files
    subtitle_moves =
      Enum.map(new_paths[:subtitle_filepaths] || [], fn [lang, new_subtitle_path] ->
        old_subtitle_path =
          Enum.find_value(media_item.subtitle_filepaths, fn [old_lang, old_path] ->
            if old_lang == lang, do: old_path
          end)

        {old_subtitle_path, new_subtitle_path}
      end)

    # Thumbnail file
    thumbnail_moves =
      if thumbnail_moves_with_media_file?(media_item) do
        [{media_item.thumbnail_filepath, new_paths[:thumbnail_filepath]}]
      else
        []
      end

    # NFO file
    nfo_moves = [{media_item.nfo_filepath, new_paths[:nfo_filepath]}]

    # The .info.json next to the media file
    info_json_moves = [{media_item.metadata_filepath, new_paths[:metadata_filepath]}]

    # Internal metadata files are stored in a metadata directory based on media_item.id,
    # so they don't need to move when the source directory changes
    Enum.filter(media_moves ++ subtitle_moves ++ thumbnail_moves ++ nfo_moves ++ info_json_moves, &file_needs_move?/1)
  end

  # A thumbnail is either in the media item's metadata directory (based on media_item.id), where it
  # doesn't need to move, or alongside the media file, where it moves with the media file
  defp thumbnail_moves_with_media_file?(%{thumbnail_filepath: nil}), do: false

  defp thumbnail_moves_with_media_file?(media_item) do
    metadata_directory = MetadataFileHelpers.metadata_directory_for(media_item)

    not FilesystemUtils.inside_directory?(media_item.thumbnail_filepath, metadata_directory)
  end

  # Makes the moves in order and stops at the first failure.
  #
  # Returns {:ok, completed_moves} | {:error, reason, completed_moves}. completed_moves
  # is newest first, which is the order to undo them in
  defp move_files(moves) do
    Enum.reduce_while(moves, {:ok, []}, fn {old_path, new_path} = move, {:ok, completed_moves} ->
      case safe_move_file(old_path, new_path) do
        :ok ->
          {:cont, {:ok, [move | completed_moves]}}

        {:error, reason} ->
          {:halt, {:error, "could not move #{old_path} to #{new_path}: #{inspect(reason)}", completed_moves}}
      end
    end)
  end

  # Moves each file back (in the order given), with the same copy-verify-delete as the
  # original move. Never raises: a file that can't be moved back is logged and returned.
  #
  # Returns [{old_path, new_path, reason}] for the moves that couldn't be undone
  defp rollback_moves(completed_moves) do
    Enum.flat_map(completed_moves, fn {old_path, new_path} ->
      case safe_move_file(new_path, old_path) do
        :ok ->
          []

        {:error, reason} ->
          Logger.error("Could not move #{new_path} back to #{old_path}: #{inspect(reason)}")
          [{old_path, new_path, reason}]
      end
    end)
  end

  # Copies the file, checks the copy is the same size as the original, then deletes the
  # original. Never overwrites an existing file, since it couldn't be restored on rollback.
  # If anything fails after the copy started, the copy is removed so the original is the
  # only one left.
  #
  # Returns :ok | {:error, reason}
  defp safe_move_file(old_path, new_path) do
    with false <- File.exists?(new_path),
         :ok <- File.mkdir_p(Path.dirname(new_path)),
         {:ok, %File.Stat{size: size}} <- File.stat(old_path) do
      copy_verify_delete(old_path, new_path, size)
    else
      true -> move_onto_existing_path(old_path, new_path)
      {:error, reason} -> {:error, reason}
    end
  end

  # An existing file at the new path is only moved onto if it's the file itself: on a
  # case-insensitive filesystem, a new path that only changes the case of the old one already
  # exists. That's renamed instead, since copying a file onto itself would destroy it
  defp move_onto_existing_path(old_path, new_path) do
    if same_file?(old_path, new_path) do
      rename_same_file(old_path, new_path)
    else
      {:error, :destination_exists}
    end
  end

  # Compares the paths' own entries, so a symlink isn't the same file as its target (renaming
  # one onto its target would replace the file with the link)
  defp same_file?(path_1, path_2) do
    with {:ok, stat_1} <- File.lstat(path_1),
         {:ok, stat_2} <- File.lstat(path_2) do
      {stat_1.major_device, stat_1.minor_device, stat_1.inode} ==
        {stat_2.major_device, stat_2.minor_device, stat_2.inode}
    else
      _ -> false
    end
  end

  # Renames through a temporary name in the same directory, since some filesystems ignore a
  # rename that only changes the case. When the paths are separate links to the file (eg: hard
  # links), the second rename does nothing, so the temporary name is removed afterwards
  defp rename_same_file(old_path, new_path) do
    tmp_path = Path.join(Path.dirname(old_path), ".pinchflat-rename-#{StringUtils.random_string(16)}")

    with :ok <- File.rename(old_path, tmp_path) do
      case File.rename(tmp_path, new_path) do
        :ok ->
          File.rm(tmp_path)
          :ok

        {:error, reason} ->
          File.rename(tmp_path, old_path)
          {:error, reason}
      end
    end
  end

  defp copy_verify_delete(old_path, new_path, size) do
    with :ok <- File.cp(old_path, new_path),
         {:ok, %File.Stat{size: ^size}} <- File.stat(new_path),
         :ok <- File.rm(old_path) do
      :ok
    else
      {:ok, %File.Stat{}} ->
        File.rm(new_path)
        {:error, :copy_size_mismatch}

      {:error, reason} ->
        File.rm(new_path)
        {:error, reason}
    end
  end

  defp get_all_media_items_for_source(source) do
    MediaQuery.new()
    |> where(^MediaQuery.for_source(source))
    |> Repo.all()
    |> Repo.preload([:metadata, source: :media_profile])
  end

  # NOTE: When operating in the ideal path, this effectively adds an API call
  # to the source creation/update process. Should be used only when needed.
  defp maybe_change_source_from_url(%Source{} = source, attrs) do
    case change_source(source, attrs) do
      %Ecto.Changeset{changes: %{original_url: _}} = changeset ->
        add_source_details_to_changeset(source, changeset)

      changeset ->
        changeset
    end
  end

  # The NFO and images are in the series directory, which other sources can share, so a file
  # another source still uses is kept. The paths come from yt-dlp, so a file outside the media
  # directory is never deleted
  defp delete_source_files(source) do
    media_directory = Application.get_env(:pinchflat, :media_directory)

    source
    |> filepaths_in(Source.filepath_attributes())
    |> Enum.reject(&file_used_by_another_source?(&1, source))
    |> Enum.each(&FilesystemUtils.delete_file_inside_directory(&1, media_directory))
  end

  defp delete_internal_metadata_files(source) do
    metadata = Repo.preload(source, :metadata).metadata || %SourceMetadata{}

    metadata
    |> filepaths_in(SourceMetadata.filepath_attributes())
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)
  end

  # Returns the record's filepaths in the given fields that are set
  defp filepaths_in(record, fields) do
    record
    |> Map.take(fields)
    |> Map.values()
    |> Enum.filter(&is_binary/1)
  end

  defp add_source_details_to_changeset(source, changeset) do
    original_url = changeset.changes.original_url
    should_use_cookies = Ecto.Changeset.get_field(changeset, :cookie_behaviour) == :all_operations
    # Skipping sleep interval since this is UI blocking and we want to keep this as fast as possible
    addl_opts = [use_cookies: should_use_cookies, skip_sleep_interval: true]

    case MediaCollection.get_source_details(original_url, [], addl_opts) do
      {:ok, source_details} ->
        add_source_details_by_collection_type(source, changeset, source_details)

      err ->
        runner_error =
          case err do
            {:error, error_msg, _status_code} -> error_msg
            {:error, error_msg} -> error_msg
          end

        Ecto.Changeset.add_error(
          changeset,
          :original_url,
          "could not fetch source details from URL",
          error: runner_error
        )
    end
  end

  defp add_source_details_by_collection_type(source, changeset, source_details) do
    %Ecto.Changeset{changes: changes} = changeset

    collection_changes =
      if source_details.playlist_id == source_details.channel_id do
        %{
          collection_type: :channel,
          collection_id: source_details.channel_id,
          collection_name: source_details.channel_name
        }
      else
        %{
          collection_type: :playlist,
          collection_id: source_details.playlist_id,
          collection_name: source_details.playlist_name
        }
      end

    change_source(source, Map.merge(changes, collection_changes))
  end

  defp maybe_change_indexing_frequency(changeset) do
    fast_index = Ecto.Changeset.get_field(changeset, :fast_index)

    if fast_index do
      Ecto.Changeset.put_change(
        changeset,
        :index_frequency_minutes,
        Source.index_frequency_when_fast_indexing()
      )
    else
      changeset
    end
  end

  defp commit_and_handle_tasks(changeset, opts) do
    run_post_commit_tasks = Keyword.get(opts, :run_post_commit_tasks, true)

    case Repo.insert_or_update(changeset) do
      {:ok, %Source{} = source} ->
        if run_post_commit_tasks do
          maybe_handle_media_tasks(changeset, source)
          maybe_run_indexing_task(changeset, source)
          maybe_run_metadata_storage_task(changeset, source)
        end

        {:ok, source}

      err ->
        err
    end
  end

  # If the source is new (ie: not persisted), do nothing
  defp maybe_handle_media_tasks(%{data: %{__meta__: %{state: state}}}, _source) when state != :loaded do
    :ok
  end

  # If the source is NOT new (ie: updated),
  # enqueue or dequeue media download tasks as necessary.
  defp maybe_handle_media_tasks(changeset, source) do
    current_changes = changeset.changes
    applied_changes = Ecto.Changeset.apply_changes(changeset)

    # We need both current_changes and applied_changes to determine
    # the course of action to take. For example, we only care if a source is supposed
    # to be `enabled` or not - we don't care if that information comes from the
    # current changes or if that's how it already was in the database.
    # Rephrased, we're essentially using it in place of `get_field/2`
    case {current_changes, applied_changes} do
      {%{download_media: true}, %{enabled: true}} ->
        DownloadingHelpers.enqueue_pending_download_tasks(source)

      {%{enabled: true}, %{download_media: true}} ->
        DownloadingHelpers.enqueue_pending_download_tasks(source)

      {%{download_media: false}, _} ->
        DownloadingHelpers.dequeue_pending_download_tasks(source)

      {%{enabled: false}, _} ->
        DownloadingHelpers.dequeue_pending_download_tasks(source)

      _ ->
        nil
    end

    :ok
  end

  defp maybe_run_indexing_task(changeset, source) do
    case changeset.data do
      # If the changeset is new (not persisted), attempt indexing whatever the index frequency,
      # unless the source is disabled. The indexing workers skip disabled sources, so this just
      # avoids enqueueing jobs that would do nothing. Enabling it is handled as an update
      %{__meta__: %{state: :built}} ->
        if source.enabled do
          SlowIndexingHelpers.kickoff_indexing_task(source)

          if Ecto.Changeset.get_field(changeset, :fast_index) do
            FastIndexingHelpers.kickoff_indexing_task(source)
          end
        end

      # If the record has been persisted, (re)start or stop indexing when the source is enabled or
      # disabled, or its index frequency or fast indexing changes. As above, indexing is only started
      # for an enabled source to avoid enqueueing jobs that would do nothing
      %{__meta__: %{state: :loaded}} ->
        maybe_update_slow_indexing_task(changeset, source)
        maybe_update_fast_indexing_task(changeset, source)
    end
  end

  defp maybe_run_metadata_storage_task(changeset, source) do
    case {changeset.data, changeset.changes} do
      # If the changeset is new (not persisted), fetch metadata no matter what
      {%{__meta__: %{state: :built}}, _} ->
        SourceMetadataStorageWorker.kickoff_with_task(source)

      # If the record has been persisted, only fetch metadata if the
      # original_url has changed
      {_, %{original_url: _}} ->
        SourceMetadataStorageWorker.kickoff_with_task(source)

      _ ->
        :ok
    end
  end

  defp maybe_update_slow_indexing_task(changeset, source) do
    # See comment in `maybe_handle_media_tasks` as to why we need these
    current_changes = changeset.changes
    applied_changes = Ecto.Changeset.apply_changes(changeset)

    case {current_changes, applied_changes} do
      {%{index_frequency_minutes: mins}, %{enabled: true}} when mins > 0 ->
        SlowIndexingHelpers.kickoff_indexing_task(source)

      {%{enabled: true}, %{index_frequency_minutes: mins}} when mins > 0 ->
        SlowIndexingHelpers.kickoff_indexing_task(source)

      {%{index_frequency_minutes: _}, _} ->
        SlowIndexingHelpers.delete_indexing_tasks(source, include_executing: true)

      {%{enabled: false}, _} ->
        SlowIndexingHelpers.delete_indexing_tasks(source, include_executing: true)

      _ ->
        :ok
    end
  end

  defp maybe_update_fast_indexing_task(changeset, source) do
    # See comment in `maybe_handle_media_tasks` as to why we need these
    current_changes = changeset.changes
    applied_changes = Ecto.Changeset.apply_changes(changeset)

    # This technically could be simplified since `maybe_update_slow_indexing_task`
    # has some overlap re: deleting pending tasks, but I'm keeping it separate
    # for clarity and explicitness.
    case {current_changes, applied_changes} do
      {%{fast_index: true}, %{enabled: true}} ->
        FastIndexingHelpers.kickoff_indexing_task(source)

      {%{enabled: true}, %{fast_index: true}} ->
        FastIndexingHelpers.kickoff_indexing_task(source)

      {%{fast_index: false}, _} ->
        Tasks.delete_pending_tasks_for(source, "FastIndexingWorker", include_executing: true)

      {%{enabled: false}, _} ->
        Tasks.delete_pending_tasks_for(source, "FastIndexingWorker", include_executing: true)

      _ ->
        :ok
    end
  end
end
