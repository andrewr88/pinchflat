defmodule Pinchflat.Podcasts.OpmlFeedBuilderTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Podcasts.OpmlFeedBuilder

  setup do
    source = source_fixture()

    {:ok, source: source}
  end

  describe "build/2" do
    test "returns an XML document", %{source: source} do
      res = OpmlFeedBuilder.build("http://example.com", [source])

      assert String.contains?(res, ~s(<?xml version="1.0" encoding="UTF-8"?>))
    end

    test "escapes illegal characters" do
      source = source_fixture(%{custom_name: "A & B"})
      res = OpmlFeedBuilder.build("http://example.com", [source])

      assert String.contains?(res, ~s(A &amp; B))
    end

    test "escapes the source's name so it can't break out of its attribute" do
      source = source_fixture(%{custom_name: ~s(A "B" <C>)})

      doc = "http://example.com" |> OpmlFeedBuilder.build([source]) |> parse_xml()

      assert xpath_string(doc, "//outline/@text") == ~s(A "B" <C>)
    end

    test "build podcast link with URL base", %{source: source} do
      res = OpmlFeedBuilder.build("http://example.com", [source])

      assert String.contains?(res, ~s(http://example.com/sources/#{source.uuid}/feed.xml))
    end
  end

  # xmerl is a strict parser, so this fails the test if the document isn't well-formed
  defp parse_xml(xml) do
    {doc, _rest} = xml |> :binary.bin_to_list() |> :xmerl_scan.string(quiet: true)

    doc
  end

  defp xpath_string(doc, path) do
    {:xmlObj, :string, value} = :xmerl_xpath.string(~c"string(#{path})", doc)

    List.to_string(value)
  end
end
