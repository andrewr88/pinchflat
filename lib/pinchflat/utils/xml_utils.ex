defmodule Pinchflat.Utils.XmlUtils do
  @moduledoc """
  Utility methods for working with XML documents
  """

  @doc """
  Escapes invalid XML characters in a string and strips characters
  that XML 1.0 doesn't allow at all (eg: most control characters)

  Returns binary()
  """
  def safe(value) do
    value
    |> to_string()
    |> strip_disallowed_characters()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  # Strips control characters other than tab, newline, and carriage return, plus U+FFFE
  # and U+FFFF (UTF-8: EF BF BE/BF). Even escaped, these make strict parsers reject the
  # whole document. See: https://www.w3.org/TR/xml/#charsets
  #
  # The regex deliberately matches bytes (no `u` flag) so invalid UTF-8 doesn't raise.
  # It's still exact for valid UTF-8 since 0x00-0x1F and 0xEF are never continuation
  # bytes, so every match is a whole character
  defp strip_disallowed_characters(string) do
    String.replace(string, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F]|\xEF\xBF[\xBE\xBF]/, "")
  end
end
