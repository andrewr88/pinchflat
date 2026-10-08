defmodule Pinchflat.Downloading.OutputPathBuilderTest do
  use Pinchflat.DataCase

  alias Pinchflat.Downloading.OutputPathBuilder

  describe "build/2" do
    test "it expands 'standard' curly brace variables in the template" do
      assert {:ok, res} = OutputPathBuilder.build("/videos/{{ title }}.{{ ext }}")

      assert res == "/videos/%(title)S.%(ext)S"
    end

    test "it expands 'custom' curly brace variables in the template" do
      assert {:ok, res} = OutputPathBuilder.build("/videos/{{ upload_year }}.{{ ext }}")

      assert res == "/videos/%(upload_date>%Y)S.%(ext)S"
    end

    test "it respects additional options" do
      assert {:ok, res} = OutputPathBuilder.build("/videos/{{ custom }}.{{ ext }}", %{"custom" => "test"})

      assert res == "/videos/test.%(ext)S"
    end

    test "it leaves yt-dlp variables alone" do
      assert {:ok, res} = OutputPathBuilder.build("/videos/%(title)s.%(ext)s")

      assert res == "/videos/%(title)s.%(ext)s"
    end

    test "recursively expands variables" do
      additional_options = %{
        "media_upload_date_index" => "99"
      }

      assert {:ok, res} = OutputPathBuilder.build("{{ season_episode_index_from_date }}.{{ ext }}", additional_options)

      assert res == "s%(upload_date>%Y)Se%(upload_date>%m%d)S99.%(ext)S"
    end

    test "inserts additional options as-is instead of expanding them as templates" do
      # Values like source names come from remote metadata (e.g. a playlist named "Best {{ of")
      template = "/{{ source_custom_name }}/{{ custom }}.{{ ext }}"
      additional_options = %{"source_custom_name" => "Best {{ of", "custom" => "{{ title }}"}

      assert {:ok, res} = OutputPathBuilder.build(template, additional_options)

      assert res == "/Best {{ of/{{ title }}.%(ext)S"
    end

    # yt-dlp expands environment variables in the template's text (not in field values) before filling it
    # in. An empty field after the `$` keeps it from naming one
    test "keeps a $ in the template's text from expanding an environment variable" do
      cases = [
        {"/$HOME/{{ title }}.{{ ext }}", "/$%(id).0sHOME/%(title)S.%(ext)S"},
        {"/Ke$ha/${X}/%(title)s.%(ext)s", "/Ke$%(id).0sha/$%(id).0s{X}/%(title)s.%(ext)s"},
        {"/100%%$HOME.{{ ext }}", "/100%%$%(id).0sHOME.%(ext)S"},
        {"/No dollar signs/{{ title }}.{{ ext }}", "/No dollar signs/%(title)S.%(ext)S"}
      ]

      for {template, expected} <- cases do
        assert OutputPathBuilder.build(template) == {:ok, expected}
      end
    end

    # A field can't have another field inside it
    test "leaves a $ inside a yt-dlp field as it is" do
      template = "/%(uploader|$HOME)s/%%(not a field $X)s.{{ ext }}"

      assert OutputPathBuilder.build(template) == {:ok, "/%(uploader|$HOME)s/%%(not a field $%(id).0sX)s.%(ext)S"}
    end
  end
end
