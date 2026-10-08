defmodule Pinchflat.Downloading.OutputPathBuilder do
  @moduledoc """
  Builds yt-dlp-friendly output paths for downloaded media
  """

  alias Pinchflat.Downloading.OutputPath.Parser, as: TemplateParser

  @doc """
  Builds the actual final filepath from a given template. Optionally, you can pass in
  a map of additional options to be used in the template.

  The built-in custom options are expanded _once_ so they can reference other options
  one-deep (e.g. `media_upload_date_index`). The additional options' values are data,
  not templates: they're inserted as-is, so `{{` in a name from remote metadata is kept
  literally instead of being expanded or breaking the parse.

  Translates liquid-style templates into yt-dlp-style templates,
  leaving yt-dlp syntax intact.
  """
  def build(template_string, additional_template_options \\ %{}) do
    custom_options = custom_yt_dlp_option_map()
    combined_options = Map.merge(custom_options, additional_template_options)

    expanded_custom_options =
      Map.new(custom_options, fn {key, value} ->
        {:ok, parse_result} = TemplateParser.parse(value, combined_options, &identifier_fn/2)

        {key, parse_result}
      end)

    template_options = Map.merge(expanded_custom_options, additional_template_options)

    TemplateParser.parse(template_string, template_options, &identifier_fn/2)
  end

  # The `nil` case simply wraps the identifier in yt-dlp-style syntax. This assumes that
  # the identifier is a valid yt-dlp option. The upside is that this gives the user
  # access to ALL single-word yt-dlp options in the (imo) more friendly/forgiving liquid-style syntax.
  #
  # For all "custom" variables, we use the `Map.get/3` function to look up the value in the provided.
  # See `custom_yt_dlp_option_map` for a list of those.
  defp identifier_fn(identifier, variables) do
    case Map.get(variables, identifier) do
      nil -> "%(#{identifier})S"
      value -> value
    end
  end

  # This isn't the only source for custom options, since they can be passed in my the caller.
  # `download_option_builder` is the most likely place for other custom options to be added,
  # but if in doubt just search the codebase for `OutputPathBuilder.build`.
  defp custom_yt_dlp_option_map do
    %{
      # Individual parts of the upload date
      "upload_year" => "%(upload_date>%Y)S",
      "upload_month" => "%(upload_date>%m)S",
      "upload_day" => "%(upload_date>%d)S",
      "upload_yyyy_mm_dd" => "%(upload_date>%Y-%m-%d)S",
      "season_from_date" => "%(upload_date>%Y)S",
      "season_episode_from_date" => "s%(upload_date>%Y)Se%(upload_date>%m%d)S",
      "season_episode_index_from_date" => "s%(upload_date>%Y)Se%(upload_date>%m%d)S{{ media_upload_date_index }}",
      "artist_name" => "%(artist,creator,uploader,uploader_id)S",
      "static_season__episode_by_index" => "Season 1/s01e{{ media_playlist_index }}",
      "static_season__episode_by_date" => "Season 1/s01e%(upload_date>%y%m%d)S",
      "season_by_year__episode_by_date" => "Season %(upload_date>%Y)S/s%(upload_date>%Y)Se%(upload_date>%m%d)S",
      "season_by_year__episode_by_date_and_index" =>
        "Season %(upload_date>%Y)S/s%(upload_date>%Y)Se%(upload_date>%m%d)S{{ media_upload_date_index }}"
    }
  end
end
