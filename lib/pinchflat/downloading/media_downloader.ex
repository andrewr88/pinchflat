defmodule Pinchflat.Downloading.MediaDownloader do
  @moduledoc """
  This is the integration layer for actually downloading media.
  It takes into account the media profile's settings in order
  to download the media with the desired options.
  """

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Utils.StringUtils
  alias Pinchflat.Metadata.NfoBuilder
  alias Pinchflat.Metadata.MetadataParser
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Downloading.DownloadOptionBuilder

  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  @doc """
  Downloads media for a media item, updating the media item based on the metadata
  returned by yt-dlp. Encountered errors are saved to the Media Item record. Saves
  the entire metadata response to the associated media_metadata record.

  NOTE: related methods (like the download worker) won't download if the media item's source
  is set to not download media. However, I'm not enforcing that here since I need this for testing.
  This may change in the future but I'm not stressed.

  Takes the `override_opts` of `DownloadOptionBuilder.build/2`, plus:
    - `redownload?`: the media is already downloaded and is downloaded again without overwriting
      its media file. If that file is still at the media file's path, it keeps its `media_downloaded_at`

  Returns {:ok, %MediaItem{}} | {:error, atom(), String.t()} | {:recovered, %MediaItem{}, String.t()}
  """
  def download_for_media_item(%MediaItem{} = media_item, override_opts \\ []) do
    case attempt_download_and_update_for_media_item(media_item, override_opts) do
      {:ok, media_item} ->
        # Returns {:ok, %MediaItem{}}
        Media.update_media_item(media_item, %{last_error: nil})

      {:error, error_atom, message} ->
        Media.update_media_item(media_item, %{last_error: StringUtils.wrap_string(message)})

        {:error, error_atom, message}

      {:recovered, media_item, message} ->
        {:ok, updated_media_item} = Media.update_media_item(media_item, %{last_error: StringUtils.wrap_string(message)})

        {:recovered, updated_media_item, message}
    end
  end

  # Looks complicated, but here's the key points:
  # - download_with_options runs a pre-check to see if the media item is suitable for download.
  # - If the media item fails the precheck, it returns {:error, :unsuitable_for_download, message}
  #   - However, if the precheck fails in a way that we think can be fixed by using cookies, we retry with cookies
  #     and return the result of that
  # - The precheck also gives the filepath yt-dlp would download the media to. If that's outside the media
  #   directory, nothing is downloaded and it returns {:error, :download_failed, message}
  # - If the precheck passes but the download fails, it normally returns {:error, :download_failed, message}
  #   - However, there are some errors we can recover from (eg: failure to communicate with SponsorBlock).
  #     In this case, we retry the download without SponsorBlock or, if that fails, use the JSON yt-dlp
  #     writes once it's finished a download (in case it did anyway). Either way the download is complete,
  #     so the media item is updated. This case returns {:recovered, updated_media_item, message}
  #   - If we attempt a retry but it fails, we return {:error, :unrecoverable, message}
  # - If there is an unknown error unrelated to the above, we return {:error, :unknown, message}
  # - Finally, if there is no error, we update the media item with the parsed JSON and return {:ok, updated_media_item}
  #
  # Restated, here are the return values for each case:
  # - On success: {:ok, updated_media_item}
  # - On initial failure but successfully recovered: {:recovered, updated_media_item, message}
  # - On error: {:error, error_atom, message} where error_atom is one of:
  #   - `:unsuitable_for_download` if the media item fails the precheck
  #   - `:unrecoverable` if there was an initial failure and the recovery attempt failed
  #   - `:download_failed` for all other yt-dlp-related downloading errors
  #   - `:update_failed` if the media was downloaded (or recovered) but the media item couldn't be saved
  #   - `:unknown` for any other errors, including those not related to yt-dlp
  # - If we retry using cookies, all of the above return values apply. The cookie retry
  #   logic is handled transparently as far as the caller is concerned
  #
  # yt-dlp's output file is deleted once all that's done (even if it raised), since recovering
  # from an error can read it
  defp attempt_download_and_update_for_media_item(media_item, override_opts) do
    output_filepath = FilesystemUtils.generate_metadata_tmpfile(:json)

    try do
      download_and_update_for_media_item(media_item, output_filepath, override_opts)
    after
      File.rm(output_filepath)
    end
  end

  defp download_and_update_for_media_item(media_item, output_filepath, override_opts) do
    media_with_preloads = Repo.preload(media_item, [:metadata, source: :media_profile])
    # Checked before downloading, which can put a new media file there
    kept_media_filepath = kept_media_filepath(media_with_preloads, override_opts)

    case download_with_options(media_item.original_url, media_with_preloads, output_filepath, override_opts) do
      {:ok, parsed_json} ->
        update_media_item_from_parsed_json(media_with_preloads, parsed_json, kept_media_filepath)

      {:error, :unsuitable_for_download} ->
        message =
          "Media item ##{media_with_preloads.id} isn't suitable for download yet. May be an active or processing live stream"

        Logger.warning(message)

        {:error, :unsuitable_for_download, message}

      {:error, {:outside_media_directory, filepath}} ->
        message =
          "Not downloading media item ##{media_with_preloads.id}: yt-dlp would save it to #{inspect(filepath)}, " <>
            "outside the media directory. A field that's a whole folder of the output template may be \"..\""

        Logger.error(message)

        {:error, :download_failed, message}

      {:error, message, _exit_code} ->
        Logger.error("yt-dlp download error for media item ##{media_with_preloads.id}: #{inspect(message)}")

        if String.contains?(to_string(message), recoverable_errors()) do
          attempt_recovery_from_error(media_with_preloads, output_filepath, message, override_opts, kept_media_filepath)
        else
          {:error, :download_failed, message}
        end

      err ->
        Logger.error("Unknown error downloading media item ##{media_with_preloads.id}: #{inspect(err)}")

        {:error, :unknown, "Unknown error: #{inspect(err)}"}
    end
  end

  # The only recoverable errors are SponsorBlock ones (see `recoverable_errors/0`), so the
  # download is retried without SponsorBlock
  defp attempt_recovery_from_error(
         media_with_preloads,
         output_filepath,
         error_message,
         override_opts,
         kept_media_filepath
       ) do
    Logger.info("""
    SponsorBlock error detected for media item ##{media_with_preloads.id}.
    Retrying download without SponsorBlock options.
    """)

    case retry_download_without_sponsorblock(media_with_preloads, override_opts) do
      {:ok, parsed_json} ->
        Logger.info("""
        Successfully recovered from SponsorBlock error for media item ##{media_with_preloads.id}
        by retrying without SponsorBlock options.
        """)

        update_recovered_media_item(media_with_preloads, parsed_json, error_message, kept_media_filepath)

      {:error, :unsuitable_for_download} ->
        Logger.warning("""
        Media item ##{media_with_preloads.id} became unsuitable for download during SponsorBlock retry.
        Falling back to parse recovery.
        """)

        attempt_parse_recovery(media_with_preloads, output_filepath, error_message, kept_media_filepath)

      {:error, retry_error_message, _exit_code} ->
        Logger.error("""
        Retry without SponsorBlock failed for media item ##{media_with_preloads.id}: #{inspect(retry_error_message)}
        """)

        # Fall back to trying to parse the original output file
        attempt_parse_recovery(media_with_preloads, output_filepath, error_message, kept_media_filepath)

      err ->
        Logger.error("""
        Unexpected error during SponsorBlock retry for media item ##{media_with_preloads.id}: #{inspect(err)}
        """)

        attempt_parse_recovery(media_with_preloads, output_filepath, error_message, kept_media_filepath)
    end
  end

  defp retry_download_without_sponsorblock(media_with_preloads, override_opts) do
    # Generate a new output filepath for the retry to avoid conflicts
    new_output_filepath = FilesystemUtils.generate_metadata_tmpfile(:json)
    # Keep the caller's options (eg: overwrite_behaviour) and only disable SponsorBlock
    override_opts = Keyword.put(override_opts, :skip_sponsorblock, true)

    # The retry's JSON is returned already parsed, so its output file isn't needed afterwards
    try do
      download_with_options(media_with_preloads.original_url, media_with_preloads, new_output_filepath, override_opts)
    after
      File.rm(new_output_filepath)
    end
  end

  # yt-dlp only writes the JSON to the output file once the media is downloaded and moved into place
  # (it's printed `after_move`), so if it's there, the download finished despite the error
  defp attempt_parse_recovery(media_with_preloads, output_filepath, error_message, kept_media_filepath) do
    with {:ok, contents} <- File.read(output_filepath),
         {:ok, parsed_json} <- Phoenix.json_library().decode(contents) do
      Logger.info("""
      Recovered from yt-dlp error for media item ##{media_with_preloads.id}: yt-dlp still finished
      the download, so the media item is updated from the JSON it wrote
      """)

      update_recovered_media_item(media_with_preloads, parsed_json, error_message, kept_media_filepath)
    else
      err ->
        Logger.error("Unable to recover error for media item ##{media_with_preloads.id}: #{inspect(err)}")

        {:error, :unrecoverable, error_message}
    end
  end

  defp update_recovered_media_item(media_with_preloads, parsed_json, error_message, kept_media_filepath) do
    with {:ok, updated_media_item} <-
           update_media_item_from_parsed_json(media_with_preloads, parsed_json, kept_media_filepath) do
      {:recovered, updated_media_item, error_message}
    end
  end

  # Returns {:ok, %MediaItem{}} | {:error, :update_failed, String.t()}
  defp update_media_item_from_parsed_json(media_with_preloads, parsed_json, kept_media_filepath) do
    parsed_attrs =
      parsed_json
      |> MetadataParser.parse_for_media_item()
      |> Map.merge(%{
        media_downloaded_at: media_downloaded_at(media_with_preloads, parsed_json["filepath"], kept_media_filepath),
        culled_at: nil,
        nfo_filepath: determine_nfo_filepath(media_with_preloads, parsed_json)
      })
      |> Map.merge(build_metadata_attrs(media_with_preloads, parsed_json))

    # Don't forgor to use preloaded associations or updates to
    # associations won't work!
    case Media.update_media_item(media_with_preloads, parsed_attrs) do
      {:ok, updated_media_item} ->
        {:ok, updated_media_item}

      {:error, changeset} ->
        message =
          "Unable to save downloaded media item ##{media_with_preloads.id}: #{format_changeset_errors(changeset)}"

        Logger.error(message)

        {:error, :update_failed, message}
    end
  end

  # A redownload doesn't overwrite the media file, so if one is on disk before downloading, it's
  # left in place unless the download's media file has a different path (eg: the output template
  # changed). Returns its path, or nil if the media file is downloaded anew
  defp kept_media_filepath(media_item, override_opts) do
    filepath = media_item.media_filepath

    if Keyword.get(override_opts, :redownload?, false) && filepath && File.exists?(filepath) do
      filepath
    end
  end

  # A media file that's left in place (ie: the download's media file is the kept one) keeps its download
  # date, which is what retention and quality upgrades go by. Anything else has just been downloaded
  defp media_downloaded_at(media_item, kept_media_filepath, kept_media_filepath) when is_binary(kept_media_filepath) do
    media_item.media_downloaded_at || DateTime.utc_now()
  end

  defp media_downloaded_at(_media_item, _media_filepath, _kept_media_filepath), do: DateTime.utc_now()

  # A metadata record needs a thumbnail (the column is NOT NULL) but fetching one can fail on its own
  # (eg: rate limiting). If it does, the record is left as-is so the download itself still gets saved.
  #
  # IDEA: might be worth kicking off a job for this since thumbnail fetching
  # could fail and I want to handle that in isolation
  defp build_metadata_attrs(media_with_preloads, parsed_json) do
    metadata_filepath = MetadataFileHelpers.compress_and_store_metadata_for(media_with_preloads, parsed_json)

    case MetadataFileHelpers.download_and_store_thumbnail_for(media_with_preloads) do
      nil ->
        Logger.warning(
          "Couldn't download a thumbnail for media item ##{media_with_preloads.id}. Leaving its metadata record as-is"
        )

        %{}

      thumbnail_filepath ->
        %{metadata: %{metadata_filepath: metadata_filepath, thumbnail_filepath: thumbnail_filepath}}
    end
  end

  # Turns a changeset's errors into a readable string, eg: "title has invalid format"
  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
      end)
    end)
    |> flatten_errors(nil)
    |> Enum.join(", ")
  end

  # Association errors are nested maps, so they're prefixed with the association's name
  defp flatten_errors(errors, prefix) do
    Enum.flat_map(errors, fn {field, field_errors} ->
      path = if prefix, do: "#{prefix}.#{field}", else: "#{field}"

      if is_map(field_errors) do
        flatten_errors(field_errors, path)
      else
        Enum.map(field_errors, &"#{path} #{StringUtils.wrap_string(&1)}")
      end
    end)
  end

  # The NFO goes next to the media file. That path comes from yt-dlp, so it's only written inside the media directory
  defp determine_nfo_filepath(media_item, parsed_json) do
    if media_item.source.media_profile.download_nfo do
      filepath = Path.rootname(parsed_json["filepath"]) <> ".nfo"

      if FilesystemUtils.inside_directory?(filepath, Application.get_env(:pinchflat, :media_directory)) do
        NfoBuilder.build_and_store_for_media_item(filepath, parsed_json)
      else
        Logger.warning(
          "Not writing an NFO for media item ##{media_item.id} to #{inspect(filepath)}: it's outside the media directory"
        )

        nil
      end
    else
      nil
    end
  end

  defp download_with_options(url, item_with_preloads, output_filepath, override_opts) do
    {:ok, options} = DownloadOptionBuilder.build(item_with_preloads, override_opts)
    force_use_cookies = Keyword.get(override_opts, :force_use_cookies, false)
    source_uses_cookies = Sources.use_cookies?(item_with_preloads.source, :downloading)
    should_use_cookies = force_use_cookies || source_uses_cookies

    runner_opts = [output_filepath: output_filepath, use_cookies: should_use_cookies]
    # With the download's output template, the check also gives the filepath the media would be downloaded to
    status_opts = [output: DownloadOptionBuilder.build_output_path_for(item_with_preloads)]

    case {YtDlpMedia.get_downloadable_status(url, status_opts, use_cookies: should_use_cookies), should_use_cookies} do
      {{:ok, :downloadable, filepath}, _} ->
        download_inside_media_directory(url, options, runner_opts, filepath)

      {{:ok, :ignorable, _filepath}, _} ->
        {:error, :unsuitable_for_download}

      {{:error, _message, _exit_code} = err, false} ->
        # If there was an error and we don't have cookies, this method will retry with cookies
        # if doing so would help AND the source allows. Otherwise, it will return the error as-is
        maybe_retry_with_cookies(url, item_with_preloads, output_filepath, override_opts, err)

      # This gets hit if cookies are enabled which, importantly, also covers the case where we
      # retry a download with cookies and it fails again
      {{:error, message, exit_code}, true} ->
        {:error, message, exit_code}

      {err, _} ->
        err
    end
  end

  # The output template is inside the media directory, but yt-dlp fills in its fields from the media's
  # metadata. It writes a field that's a whole folder of the template as-is even if it's "..", and can turn
  # other values into ".." when it makes them filename-safe. So the filepath yt-dlp gives the media is
  # checked before anything is downloaded. yt-dlp works the filepath out before it gives the live status,
  # failing if it can't, so it's only missing if something else gave the status
  defp download_inside_media_directory(url, options, runner_opts, filepath) do
    media_directory = Application.get_env(:pinchflat, :media_directory)

    if is_nil(filepath) or FilesystemUtils.inside_directory?(filepath, media_directory) do
      YtDlpMedia.download(url, options, runner_opts)
    else
      {:error, {:outside_media_directory, filepath}}
    end
  end

  defp maybe_retry_with_cookies(url, item_with_preloads, output_filepath, override_opts, err) do
    {:error, message, _} = err
    source = item_with_preloads.source
    message_contains_cookie_error = String.contains?(to_string(message), recoverable_cookie_errors())

    if Sources.use_cookies?(source, :error_recovery) && message_contains_cookie_error do
      download_with_options(
        url,
        item_with_preloads,
        output_filepath,
        Keyword.put(override_opts, :force_use_cookies, true)
      )
    else
      err
    end
  end

  defp recoverable_errors do
    [
      "Unable to communicate with SponsorBlock"
    ]
  end

  defp recoverable_cookie_errors do
    [
      "Sign in to confirm",
      "This video is available to this channel's members"
    ]
  end
end
