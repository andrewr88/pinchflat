defmodule Pinchflat.SlowIndexing.SlowIndexingHelpers do
  @moduledoc """
  Methods for performing slow indexing tasks and managing the indexing process.

  Many of these methods are made to be kickoff or be consumed by workers.
  """

  use Pinchflat.Media.MediaQuery

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.YtDlp.MediaCollection
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.SlowIndexing.FileFollowerServer
  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker

  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  # yt-dlp's output can be very long (eg: one error per media item) so only log the start of it
  @logged_output_limit 500
  # How many first indexes in a row can be incomplete before the source is marked as indexed anyway
  @max_incomplete_first_indexes 3

  @doc """
  Kills old indexing tasks and starts a new task to index the media collection.

  The job is delayed based on the source's `index_frequency_minutes` setting unless
  one of the following is true:
    - The `force` option is set to true
    - The source has never been indexed before
    - The source has been indexed before, but the last indexing job was more than
      `index_frequency_minutes` ago

  Returns {:ok, %Task{}}
  """
  def kickoff_indexing_task(%Source{} = source, job_args \\ %{}, job_opts \\ []) do
    job_offset_seconds = if job_args[:force], do: 0, else: calculate_job_offset_seconds(source)

    Tasks.delete_pending_tasks_for(source, "MediaCollectionIndexingWorker", include_executing: true)

    MediaCollectionIndexingWorker.kickoff_with_task(source, job_args, job_opts ++ [schedule_in: job_offset_seconds])
  end

  @doc """
  A helper method to delete all indexing-related tasks for a source.
  Optionally, you can include executing tasks in the deletion process.

  Returns :ok
  """
  def delete_indexing_tasks(%Source{} = source, opts \\ []) do
    include_executing = Keyword.get(opts, :include_executing, false)

    Tasks.delete_pending_tasks_for(source, "FastIndexingWorker", include_executing: include_executing)
    Tasks.delete_pending_tasks_for(source, "MediaCollectionIndexingWorker", include_executing: include_executing)
  end

  @doc """
  Given a media source, creates (indexes) the media by creating media_items for each
  media ID in the source. Afterward, kicks off a download task for each pending media
  item belonging to the source. Returns a list of media items or changesets
  (if the media item couldn't be created).

  Indexing is slow and usually returns a list of all media data at once for record creation.
  To help with this, we use a file follower to watch the file that yt-dlp writes to
  so we can create media items as they come in. This parallelizes the process and adds
  clarity to the user experience. This has a few things to be aware of which are documented
  below in the file watcher setup method.

  Additionally, in the case of a repeat index we create a download archive file that
  contains some media IDs that we've indexed in the past. Note that this archive doesn't
  contain the most recent IDs but rather a subset of IDs that are offset by some amount.
  Practically, this means that we'll re-index a small handful of media that we've recently
  indexed, but this is a good thing since it'll let us pick up on any recent changes to the
  most recent media items.

  We don't create a download archive for playlists (only channels), nor do we create one if
  the indexing was forced by the user.

  A channel that scans its tabs separately (see `Sources.indexing_urls/1`) is indexed with one yt-dlp
  run per tab it scans, each with its own file follower and download archive. A tab's archive only has
  media from that tab (see `MediaQuery.in_channel_tab/1`) since the tab would never reach any other media,
  so a tab whose media hasn't been indexed yet (eg: one that's just been turned on) is indexed all the way
  through. A tab the channel doesn't have (eg: a Live tab if it's never streamed) just has nothing to index.
  The runs make up one index: it's complete if every tab's run is, failed if every tab's run failed, and
  partial (see below) otherwise, eg: if yt-dlp didn't get through one of the tabs.

  NOTE: downloads are only enqueued if the source is set to download media. Downloads are
  also enqueued for ALL pending media items, not just the ones that were indexed in this
  job run. This should ensure that any stragglers are caught if, for some reason, they
  weren't enqueued or somehow got de-queued.

  If yt-dlp fails, the error is logged and `{:error, :indexing_failed}` is returned. The source
  isn't marked as indexed (ie: `last_indexed_at` isn't updated) but any media items the file
  follower created before the failure are kept and downloads are still enqueued for pending
  media items.

  yt-dlp exiting with 1 after writing _some_ media is different since yt-dlp carries on after an
  error. It does that whenever any single media item fails (eg: members-only, private, or
  age-restricted media) but also when an error like a bot check fails every media item after
  the ones it wrote. The media it wrote is indexed either way (logging a warning) and downloads
  are enqueued. A source that's been indexed before is marked as indexed since, otherwise, one
  inaccessible media item would fail every index of the source. A source's first index isn't
  marked as indexed though, and `{:error, :indexing_incomplete}` is returned. Its next index would
  otherwise use a download archive of the media found here, stopping before it got to anything
  older, so it'd never be indexed. This way, the next index is a full one again.

  A source with media yt-dlp can never get (eg: a video that's permanently unavailable) would never
  finish its first index though, making every index a slow, full one. So once #{@max_incomplete_first_indexes}
  first indexes in a row are incomplete (counted by the source's `incomplete_first_index_count`), the
  source is marked as indexed anyway, logging a warning, and the media items are returned. An index
  that's complete marks the source as indexed and starts the count again, while one that fails without
  writing any media doesn't count.

  Available options:
    - `was_forced`: Whether the indexing was forced by the user
    - `on_new_media_items`: A function that's called with the media items this index created
      (ie: that didn't already exist) once it's done, even if it failed. Eg: to notify about new
      media. Comparing the source's media items from before and after indexing would also count
      any that something else (eg: a fast index) created for the source in the meantime

  Returns [%MediaItem{} | %Ecto.Changeset{}] | {:error, :indexing_failed} | {:error, :indexing_incomplete}
  """
  def index_and_enqueue_download_for_media_items(%Source{} = source, opts \\ []) do
    # The media_profile is needed to determine the quality options to _then_ determine a more
    # accurate predicted filepath
    source = Repo.preload(source, [:media_profile])
    # See the method definitions below for more info on how a source's URLs are indexed and how
    # file watchers work (important reading if you're not familiar with it)
    indexing_result = index_source_urls(source, opts)
    # Reload because the source may have been updated during the (long-running) indexing process
    # and important settings like `download_media` may have changed.
    source = Repo.reload!(source)
    # The file follower has stopped by now so it's reported every media item it created
    followed_media_items = receive_followed_media_items()

    {result, created_media_items} = handle_indexing_result(source, indexing_result)
    # Media items the file follower created are kept even if indexing failed so, either way,
    # make sure every pending media item has a download enqueued
    DownloadingHelpers.enqueue_pending_download_tasks(source)

    on_new_media_items = Keyword.get(opts, :on_new_media_items, fn _media_items -> :ok end)
    on_new_media_items.(Enum.uniq_by(followed_media_items ++ created_media_items, & &1.id))

    result
  end

  defp handle_indexing_result(source, {:ok, media_attributes}) do
    {media_items, created_media_items} = create_media_items(source, media_attributes)
    mark_as_indexed(source)

    {media_items, created_media_items}
  end

  # See the docs above for why a source's first index usually isn't marked as indexed here
  defp handle_indexing_result(source, {:partial, media_attributes}) do
    {media_items, created_media_items} = create_media_items(source, media_attributes)
    incomplete_first_index_count = source.incomplete_first_index_count + 1

    cond do
      source.last_indexed_at ->
        mark_as_indexed(source)

        {media_items, created_media_items}

      incomplete_first_index_count >= @max_incomplete_first_indexes ->
        Logger.warning(
          "Marking source #{source.id} #{inspect(source.custom_name)} as indexed even though yt-dlp didn't finish " <>
            "its first index #{incomplete_first_index_count} times in a row (eg: it has media yt-dlp can't get). " <>
            "From now on, its indexes only look for new media unless they're forced, so older media that yt-dlp " <>
            "didn't get to may be missing"
        )

        mark_as_indexed(source)

        {media_items, created_media_items}

      true ->
        Logger.warning("Not marking source #{source.id} as indexed since yt-dlp didn't finish its first index")
        Sources.update_source(source, %{incomplete_first_index_count: incomplete_first_index_count})

        {{:error, :indexing_incomplete}, created_media_items}
    end
  end

  defp handle_indexing_result(source, error) do
    Logger.error("Failed to index source #{source.id}: #{inspect(error, printable_limit: @logged_output_limit)}")

    {{:error, :indexing_failed}, []}
  end

  defp mark_as_indexed(source) do
    Sources.update_source(source, %{last_indexed_at: DateTime.utc_now(), incomplete_first_index_count: 0})
  end

  # Runs yt-dlp for each URL the source is indexed with (see `Sources.indexing_urls/1`), one after the other,
  # and combines their results into one (see the docs above)
  defp index_source_urls(source, opts) do
    results =
      for {tab, url} <- Sources.indexing_urls(source) do
        source
        |> setup_file_watcher_and_kickoff_indexing(tab, url, opts)
        |> handle_tab_result(source, tab, url)
      end

    {indexed, failed} = Enum.split_with(results, &match?({status, _} when status in [:ok, :partial], &1))
    media_attributes = Enum.flat_map(indexed, fn {_status, media_attributes} -> media_attributes end)

    cond do
      indexed == [] and failed != [] -> hd(failed)
      failed == [] and Enum.all?(indexed, &match?({:ok, _}, &1)) -> {:ok, media_attributes}
      true -> {:partial, media_attributes}
    end
  end

  # A source's own URL is handled as it always is. yt-dlp fails without writing anything for a tab the
  # channel doesn't have (eg: "ERROR: [youtube:tab] @handle: This channel does not have a streams tab"
  # if it's never streamed), which just means there's nothing to index there
  defp handle_tab_result(result, _source, nil = _tab, _url), do: result
  defp handle_tab_result({status, _} = result, _source, _tab, _url) when status in [:ok, :partial], do: result

  defp handle_tab_result(error, source, _tab, url) do
    if missing_tab_error?(error) do
      Logger.info("Nothing to index at #{url} for source #{source.id} since the channel doesn't have that tab")

      {:ok, []}
    else
      Logger.warning(
        "Failed to index #{url} for source #{source.id}: #{inspect(error, printable_limit: @logged_output_limit)}"
      )

      error
    end
  end

  defp missing_tab_error?({:error, output, 1}) when is_binary(output) do
    output =~ ~r/This channel does not have an? \S+ tab/
  end

  defp missing_tab_error?(_error), do: false

  # The file follower is a GenServer that watches a file for new lines and
  # processes them. This works well, but we have to be resilliant to partially-written
  # lines (ie: you should gracefully fail if you can't parse a line).
  #
  # This works in-tandem with the normal (blocking) media indexing behaviour. When
  # the `setup_file_watcher_and_kickoff_indexing` method completes it'll return the
  # FULL result to the caller for parsing. Ideally, every item in the list will have already
  # been processed by the file follower, but if not, the caller handles creation
  # of any media items that were missed/initially failed.
  #
  # It shuts down the file follower after the indexing is done, but the FileFollowerServer
  # will also stop itself if it doesn't see any activity for a sufficiently long time.
  #
  # If yt-dlp fails, its error is returned instead of the FULL result. The exception is
  # handled by `maybe_use_partial_output/3`, which needs yt-dlp's output file. That's why
  # the file is created here rather than by `MediaCollection`.
  #
  # The temporary files (yt-dlp's output and the download archive) are deleted once indexing
  # is done, even if it raised. The file follower is stopped first so it's done with yt-dlp's output.
  defp setup_file_watcher_and_kickoff_indexing(source, tab, url, opts) do
    was_forced = Keyword.get(opts, :was_forced, false)
    should_use_cookies = Sources.use_cookies?(source, :indexing)

    command_opts =
      [output: DownloadOptionBuilder.build_output_path_for(source)] ++
        DownloadOptionBuilder.build_quality_options_for(source)

    archive_options = build_download_archive_options(source, tab, was_forced)
    output_filepath = FilesystemUtils.generate_metadata_tmpfile(:json)
    {:ok, pid} = FileFollowerServer.start_link()
    caller = self()

    handler = fn filepath -> setup_file_follower_watcher(pid, filepath, source, caller) end
    runner_opts = [output_filepath: output_filepath, file_listener_handler: handler, use_cookies: should_use_cookies]

    try do
      url
      |> MediaCollection.get_media_attributes_for_collection(command_opts ++ archive_options, runner_opts)
      |> maybe_use_partial_output(output_filepath, source)
    after
      FileFollowerServer.stop(pid)

      [output_filepath, Keyword.get(archive_options, :download_archive)]
      |> Enum.reject(&is_nil/1)
      |> Enum.each(&File.rm/1)
    end
  end

  # yt-dlp exits with 1 if ANY media item fails (eg: members-only, private, or age-restricted media)
  # but it carries on and still writes every other media item it can to the output file, so use those
  # rather than failing the whole index. That's only a partial index though (see the docs for
  # `index_and_enqueue_download_for_media_items/2`). The file follower can't be relied on for this since
  # it can miss lines written just before yt-dlp exits. Other exit statuses (eg: yt-dlp being killed
  # part-way through) and a 1 without any media written are left as failures.
  defp maybe_use_partial_output({:error, output, 1} = error, filepath, source) do
    with {:ok, contents} <- File.read(filepath),
         [_ | _] = media_attributes <- parse_media_attributes(contents) do
      trimmed_output = inspect(output, printable_limit: @logged_output_limit)

      Logger.warning(
        "yt-dlp failed to index some media for source #{source.id}. " <>
          "Indexing the #{length(media_attributes)} media item(s) it did find: #{trimmed_output}"
      )

      {:partial, media_attributes}
    else
      _ -> error
    end
  end

  defp maybe_use_partial_output(result, _filepath, _source), do: result

  defp parse_media_attributes(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Phoenix.json_library().decode(line) do
        {:ok, media_attrs} -> [YtDlpMedia.response_to_struct(media_attrs)]
        _ -> []
      end
    end)
  end

  # The handler runs in the file follower's process so it reports the media items it creates
  # to the indexing process (`caller`)
  defp setup_file_follower_watcher(pid, filepath, source, caller) do
    FileFollowerServer.watch_file(pid, filepath, fn line ->
      case Phoenix.json_library().decode(line) do
        {:ok, media_attrs} ->
          Logger.debug("FileFollowerServer Handler: Got media attributes: #{inspect(media_attrs)}")

          create_media_item_and_enqueue_download(source, media_attrs, caller)

        err ->
          Logger.debug("FileFollowerServer Handler: Error decoding JSON: #{inspect(err)}")

          err
      end
    end)
  end

  defp receive_followed_media_items(media_items \\ []) do
    receive do
      {:followed_media_item_created, media_item} -> receive_followed_media_items([media_item | media_items])
    after
      0 -> media_items
    end
  end

  # Returns the media items (or changesets) along with the media items that were created here rather
  # than already existing (eg: having been created by the file follower or a fast index)
  defp create_media_items(source, media_attributes) do
    existing_media_ids = source |> list_media_ids() |> MapSet.new()
    media_items = Enum.map(media_attributes, &create_media_item_or_changeset(source, &1))

    created_media_items =
      for %MediaItem{} = media_item <- media_items,
          not MapSet.member?(existing_media_ids, media_item.media_id),
          do: media_item

    {media_items, created_media_items}
  end

  defp create_media_item_or_changeset(source, media_attrs) do
    case Media.create_media_item_from_backend_attrs(source, media_attrs) do
      {:ok, media_item} -> media_item
      {:error, changeset} -> changeset
    end
  end

  # This runs in the file follower, which is linked to the indexing job, so raising here (eg: if the
  # database is busy) would kill the whole index. Indexing creates any media item that's missed here
  # once yt-dlp is done so the error is just logged.
  defp create_media_item_and_enqueue_download(source, media_attrs, caller) do
    media_struct = YtDlpMedia.response_to_struct(media_attrs)
    # Reload because the source may have been updated during the (long-running) indexing process
    # and important settings like `download_media` may have changed.
    source = Repo.reload!(source)
    # Something else (eg: a fast index) may have created it already, in which case it isn't new
    is_new = not media_item_exists?(source, media_struct.media_id)

    case Media.create_media_item_from_backend_attrs(source, media_struct) do
      {:ok, %MediaItem{} = media_item} ->
        if is_new, do: send(caller, {:followed_media_item_created, media_item})

        DownloadingHelpers.kickoff_download_if_pending(media_item)

      {:error, changeset} ->
        changeset
    end
  rescue
    error ->
      media_id = if is_map(media_attrs), do: media_attrs["id"]

      Logger.warning(
        "FileFollowerServer Handler: Couldn't create media item #{inspect(media_id)} for source #{source.id}. " <>
          "Leaving it to the end of indexing: #{Exception.message(error)}"
      )

      {:error, error}
  end

  defp media_item_exists?(_source, nil), do: false

  defp media_item_exists?(source, media_id) do
    MediaQuery.new()
    |> where(^dynamic([mi], ^MediaQuery.for_source(source) and mi.media_id == ^media_id))
    |> Repo.exists?()
  end

  defp list_media_ids(source) do
    MediaQuery.new()
    |> where(^MediaQuery.for_source(source))
    |> select([mi], mi.media_id)
    |> Repo.all()
  end

  # Find the difference between the current time and the last time the source was indexed
  defp calculate_job_offset_seconds(%Source{last_indexed_at: nil}), do: 0

  defp calculate_job_offset_seconds(source) do
    offset_seconds = DateTime.diff(DateTime.utc_now(), source.last_indexed_at, :second)
    index_frequency_seconds = source.index_frequency_minutes * 60

    max(0, index_frequency_seconds - offset_seconds)
  end

  # The download archive file works in tandem with --break-on-existing to stop
  # yt-dlp once we've hit media items we've already indexed. But we generate
  # this list with a bit of an offset so we do intentionally re-scan some media
  # items to pick up any recent changes (see `get_media_items_for_download_archive`).
  #
  # From there, we format the media IDs in the way that yt-dlp expects (ie: "<extractor> <media_id>")
  # and return the filepath to the caller.
  defp create_download_archive_file(source, tab) do
    tmpfile = FilesystemUtils.generate_metadata_tmpfile(:txt)

    archive_contents =
      source
      |> get_media_items_for_download_archive(tab)
      |> Enum.map_join("\n", fn media_item -> "youtube #{media_item.media_id}" end)

    case File.write(tmpfile, archive_contents) do
      :ok ->
        {:ok, tmpfile}

      {:error, reason} ->
        File.rm(tmpfile)

        Logger.warning(
          "Couldn't write a download archive for source #{source.id}, indexing without one: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Sorting by `uploaded_at` is important because we want to re-index the most recent
  # media items first but there is no guarantee of any correlation between ID and uploaded_at.
  #
  # The offset is important because we want to re-index some media items that we've
  # recently indexed to pick up on any changes. The limit is because we want this mechanism
  # to work even if, for example, the video we were using as a stopping point was deleted.
  # It's not a perfect system, but it should do well enough.
  #
  # The chosen limit and offset are arbitary, independent, and vibes-based. Feel free to
  # tweak as-needed
  #
  # A channel's tab only stops at its own media since it never reaches any other. Otherwise, a tab
  # with less recent media than the others would have nothing to stop at and be indexed all the way
  # through every time
  defp get_media_items_for_download_archive(source, tab) do
    MediaQuery.new()
    |> where(^MediaQuery.for_source(source))
    |> maybe_in_channel_tab(tab)
    |> order_by(desc: :uploaded_at)
    |> limit(50)
    |> offset(20)
    |> Repo.all()
  end

  defp maybe_in_channel_tab(query, nil), do: query
  defp maybe_in_channel_tab(query, tab), do: where(query, ^MediaQuery.in_channel_tab(tab))

  # The download archive isn't useful for playlists (since those are ordered arbitrarily)
  # and we don't want to use it if the indexing was forced by the user. In other words,
  # only create an archive for channels that are being indexed as part of their regular
  # indexing schedule. The first indexing pass should also not create an archive.
  defp build_download_archive_options(%Source{collection_type: :playlist}, _tab, _was_forced), do: []
  defp build_download_archive_options(%Source{last_indexed_at: nil}, _tab, _was_forced), do: []
  defp build_download_archive_options(_source, _tab, true), do: []

  # Without an archive, yt-dlp indexes everything rather than stopping at media it's seen before
  defp build_download_archive_options(source, tab, _was_forced) do
    case create_download_archive_file(source, tab) do
      {:ok, archive_file} -> [:break_on_existing, download_archive: archive_file]
      {:error, _reason} -> []
    end
  end
end
