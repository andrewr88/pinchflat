defmodule Pinchflat.Utils.XmlUtilsTest do
  use Pinchflat.DataCase

  alias Pinchflat.Utils.XmlUtils

  describe "safe/1" do
    test "escapes invalid characters" do
      assert XmlUtils.safe("hello' & <world>") == "hello&#39; &amp; &lt;world&gt;"
    end

    test "converts input to string" do
      assert XmlUtils.safe(42) == "42"
      assert XmlUtils.safe(nil) == ""
    end

    test "strips characters that are not allowed in XML" do
      assert XmlUtils.safe("a\vb") == "ab"
      assert XmlUtils.safe(<<?a, 0x00, 0x01, 0x08, 0x0B, 0x0C, 0x0E, 0x1F, ?b>>) == "ab"
      assert XmlUtils.safe("a\uFFFEb\uFFFFc") == "abc"
    end

    test "keeps whitespace and other characters that are allowed in XML" do
      assert XmlUtils.safe("a\tb\nc\r\nd") == "a\tb\nc\r\nd"
      assert XmlUtils.safe("é 日本 🎉 \uFFFD") == "é 日本 🎉 \uFFFD"
    end

    test "does not raise on invalid UTF-8" do
      assert XmlUtils.safe(<<0xFF, ?a, 0x0B, ?b>>) == <<0xFF, ?a, ?b>>
    end
  end
end
