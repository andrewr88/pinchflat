defmodule Pinchflat.Downloading.DownloadOptionBuilder do
  @moduledoc """
  Builds the options for yt-dlp to download media based on the given media profile.
  """

  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Downloading.OutputPathBuilder
  alias Pinchflat.Downloading.QualityOptionBuilder

  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @doc """
  Builds the options for yt-dlp to download media based on the given media's profile.

  Returns {:ok, [Keyword.t()]}
  """
  def build(%MediaItem{} = media_item_with_preloads, override_opts \\ []) do
    media_profile = media_item_with_preloads.source.media_profile

    built_options =
      default_options(override_opts) ++
        subtitle_options(media_profile) ++
        thumbnail_options(media_item_with_preloads) ++
        metadata_options(media_profile) ++
        quality_options(media_profile) ++
        sponsorblock_options(media_profile, override_opts) ++
        output_options(media_item_with_preloads) ++
        config_file_options(media_item_with_preloads)

    {:ok, built_options}
  end

  @doc """
  Builds the output path for yt-dlp to download media based on the given source's
  or media_item's media profile. Uses the source's override output path template if it exists.

  Accepts a %MediaItem{} or %Source{} struct. If a %Source{} struct is passed, it
  will use a default %MediaItem{} struct with the given source.

  Returns binary()
  """
  def build_output_path_for(%Source{} = source_with_preloads) do
    build_output_path_for(%MediaItem{source: source_with_preloads})
  end

  def build_output_path_for(%MediaItem{} = media_item_with_preloads) do
    output_path_template = Sources.output_path_template(media_item_with_preloads.source)

    build_output_path(output_path_template, media_item_with_preloads)
  end

  @doc """
  Builds the quality options for yt-dlp to download media based on the given source's
  or media_item's media profile. Useful for helping predict final filepath of downloaded
  media.

  returns [Keyword.t()]
  """
  def build_quality_options_for(%Source{} = source_with_preloads) do
    build_quality_options_for(%MediaItem{source: source_with_preloads})
  end

  def build_quality_options_for(%MediaItem{} = media_item_with_preloads) do
    media_profile = media_item_with_preloads.source.media_profile

    quality_options(media_profile)
  end

  defp default_options(override_opts) do
    overwrite_behaviour = Keyword.get(override_opts, :overwrite_behaviour, :force_overwrites)

    [
      :no_progress,
      overwrite_behaviour,
      # This makes the date metadata conform to what jellyfin expects
      parse_metadata: "%(upload_date>%Y-%m-%d)s:(?P<meta_date>.+)"
    ]
  end

  # Subtitles can't be embedded in audio, so `embed_subs` does nothing for audio (not even
  # fetching subtitles to embed). `download_subs` is unaffected
  defp subtitle_options(media_profile) do
    mapped_struct = Map.from_struct(media_profile)

    Enum.reduce(mapped_struct, [], fn attr, acc ->
      case {attr, media_profile} do
        {{:download_subs, true}, _} ->
          # Force SRT for now - MAY provide as an option in the future
          acc ++ [:write_subs, convert_subs: "srt"]

        {{:download_auto_subs, true}, %{download_subs: true}} ->
          acc ++ [:write_auto_subs]

        {{:download_auto_subs, true}, %{embed_subs: true, preferred_resolution: pr}} when pr != :audio ->
          acc ++ [:write_auto_subs]

        {{:embed_subs, true}, %{preferred_resolution: pr}} when pr != :audio ->
          acc ++ [:embed_subs]

        {{:sub_langs, sub_langs}, %{download_subs: true}} ->
          acc ++ [sub_langs: sub_langs]

        {{:sub_langs, sub_langs}, %{embed_subs: true, preferred_resolution: pr}} when pr != :audio ->
          acc ++ [sub_langs: sub_langs]

        _ ->
          acc
      end
    end)
  end

  defp thumbnail_options(media_item_with_preloads) do
    media_profile = media_item_with_preloads.source.media_profile
    mapped_struct = Map.from_struct(media_profile)

    Enum.reduce(mapped_struct, [], fn attr, acc ->
      case attr do
        {:download_thumbnail, true} ->
          thumbnail_save_location = determine_thumbnail_location(media_item_with_preloads)

          acc ++ [:write_thumbnail, convert_thumbnail: "jpg", output: "thumbnail:#{thumbnail_save_location}"]

        {:embed_thumbnail, true} ->
          acc ++ [:embed_thumbnail, convert_thumbnail: "jpg"]

        _ ->
          acc
      end
    end)
  end

  defp metadata_options(media_profile) do
    mapped_struct = Map.from_struct(media_profile)

    Enum.reduce(mapped_struct, [], fn attr, acc ->
      case attr do
        {:download_metadata, true} -> acc ++ [:write_info_json, :clean_info_json]
        {:embed_metadata, true} -> acc ++ [:embed_metadata]
        _ -> acc
      end
    end)
  end

  defp quality_options(media_profile) do
    QualityOptionBuilder.build(media_profile)
  end

  defp sponsorblock_options(media_profile, override_opts) do
    # Skip sponsorblock if explicitly requested in override_opts
    if Keyword.get(override_opts, :skip_sponsorblock, false) do
      []
    else
      categories = media_profile.sponsorblock_categories
      behaviour = media_profile.sponsorblock_behaviour

      case {behaviour, categories} do
        {_, []} -> []
        {:remove, _} -> [sponsorblock_remove: Enum.join(categories, ",")]
        {:mark, _} -> [sponsorblock_mark: Enum.join(categories, ",")]
        {:disabled, _} -> []
      end
    end
  end

  # This is put here instead of the CommandRunner module because it should only
  # be applied to downloading - if it were in CommandRunner it would apply to
  # all yt-dlp commands (like indexing)
  defp config_file_options(media_item) do
    base_dir = Path.join(Application.get_env(:pinchflat, :extras_directory), "yt-dlp-configs")
    # Ordered by priority - the first file has the highest priority
    filenames = [
      "media-item-#{media_item.id}-config.txt",
      "source-#{media_item.source_id}-config.txt",
      "media-profile-#{media_item.source.media_profile_id}-config.txt",
      "base-config.txt"
    ]

    config_filepaths =
      Enum.reduce(filenames, [], fn filename, acc ->
        filepath = Path.join(base_dir, filename)

        if FSUtils.exists_and_nonempty?(filepath) do
          [filepath | acc]
        else
          acc
        end
      end)

    Enum.map(config_filepaths, fn filepath -> {:config_locations, filepath} end)
  end

  defp output_options(media_item_with_preloads) do
    [
      output: build_output_path_for(media_item_with_preloads)
    ]
  end

  defp build_output_path(string, media_item_with_preloads) do
    additional_options_map = output_options_map(media_item_with_preloads)
    {:ok, output_path} = OutputPathBuilder.build(string, additional_options_map)

    base_directory()
    |> Path.join(output_path)
    |> ensure_in_base_directory!()
  end

  defp output_options_map(media_item_with_preloads) do
    source = media_item_with_preloads.source

    %{
      "media_item_id" => to_string(media_item_with_preloads.id),
      "source_id" => to_string(source.id),
      "media_profile_id" => to_string(source.media_profile_id),
      "source_custom_name" => escape_source_name(source.custom_name),
      "source_collection_id" => escape_source_name(source.collection_id),
      "source_collection_name" => escape_source_name(source.collection_name),
      "source_collection_type" => to_string(source.collection_type),
      "media_playlist_index" => pad_int(media_item_with_preloads.playlist_index),
      "media_upload_date_index" => pad_int(media_item_with_preloads.upload_date_index)
    }
  end

  # These come from the channel or playlist's metadata (custom_name defaults to the
  # collection name), so they're made safe to use as one literal path segment of the
  # yt-dlp output template. Any other name is unchanged:
  #   - `/` and `\` become the lookalikes yt-dlp itself uses for them in field values
  #     (`⧸` U+29F8 and `⧹` U+29F9), so a name can't add or climb directory levels and
  #     "AC/DC" gets the same folder name as `%(channel)S` would give it
  #   - a name that's just `.` or `..` would be a relative path segment, so its dots become `_`
  #   - `%` is doubled so yt-dlp writes it as-is instead of expanding e.g. `%(id)s` as a field
  #     (yt-dlp already wrote a lone `%` as-is, so a name like "100% Real" keeps its path)
  defp escape_source_name(name) when name in [".", ".."] do
    String.replace(name, ".", "_")
  end

  defp escape_source_name(name) do
    name
    |> String.replace("/", "⧸")
    |> String.replace("\\", "⧹")
    |> String.replace("%", "%%")
  end

  # The final path must be inside the media directory, however the template and the names in
  # it combine. Raises (like an unparseable template would) since every caller needs a path
  defp ensure_in_base_directory!(output_path) do
    if FSUtils.inside_directory?(output_path, base_directory()) do
      output_path
    else
      raise "Output path #{inspect(output_path)} is outside the media directory #{inspect(base_directory())}"
    end
  end

  # I don't love the string manipulation here, but what can ya' do.
  # It's dependent on the output_path_template being a string ending `.{{ ext }}`
  # (or equivalent), but that's validated by the MediaProfile schema.
  defp determine_thumbnail_location(media_item_with_preloads) do
    output_path_template = Sources.output_path_template(media_item_with_preloads.source)

    output_path_template
    |> String.split(~r{\.}, include_captures: true)
    |> List.insert_at(-3, "-thumb")
    |> Enum.join()
    |> build_output_path(media_item_with_preloads)
  end

  defp pad_int(integer, count \\ 2, padding \\ "0") do
    integer
    |> to_string()
    |> String.pad_leading(count, padding)
  end

  defp base_directory do
    Application.get_env(:pinchflat, :media_directory)
  end
end
