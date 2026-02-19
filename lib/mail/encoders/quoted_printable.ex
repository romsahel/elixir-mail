defmodule Mail.Encoders.QuotedPrintable do
  @moduledoc """
  Encodes/decodes quoted-printable strings according to RFC 2045.

  See the following links for reference:
  - <https://tools.ietf.org/html/rfc2045#section-6.7>
  """

  @new_line "=\r\n"
  @max_length 76
  @reserved_chars [?=, ??, ?_]

  @doc """
  Encodes a string into a quoted-printable encoded string.

  ## Examples

      Mail.Encoders.QuotedPrintable.encode("façade")
      "fa=C3=A7ade"
  """
  @spec encode(binary) :: binary
  @spec encode(binary, integer, binary, non_neg_integer) :: binary
  def encode(string, max_length \\ @max_length, acc \\ <<>>, line_length \\ 0)

  def encode(<<>>, _, acc, _), do: acc

  # Encode ASCII characters in range 0x20..0x7E, except reserved symbols: 0x3F (question mark), 0x3D (equal sign) and 0x5F (underscore)
  def encode(<<char, tail::binary>>, max_length, acc, line_length)
      when char in ?!..?~ and char not in @reserved_chars do
    if line_length < max_length - 1 do
      encode(tail, max_length, acc <> <<char>>, line_length + 1)
    else
      encode(tail, max_length, acc <> @new_line <> <<char>>, 1)
    end
  end

  # Encode ASCII tab and space characters.
  def encode(<<char, tail::binary>>, max_length, acc, line_length) when char in [?\t, ?\s] do
    # if remaining > 0 do
    if byte_size(tail) > 0 do
      if line_length < max_length - 1 do
        encode(tail, max_length, acc <> <<char>>, line_length + 1)
      else
        encode(tail, max_length, acc <> @new_line <> <<char>>, 1)
      end
    else
      escaped = "=" <> Base.encode16(<<char>>)
      line_length = line_length + byte_size(escaped)

      if line_length <= max_length do
        encode(tail, max_length, acc <> escaped, line_length)
      else
        encode(tail, max_length, acc <> @new_line <> escaped, byte_size(escaped))
      end
    end
  end

  # Encode all other characters.
  def encode(<<char, tail::binary>>, max_length, acc, line_length) do
    escaped = "=" <> Base.encode16(<<char>>)
    line_length = line_length + byte_size(escaped)

    if line_length < max_length do
      encode(tail, max_length, acc <> escaped, line_length)
    else
      encode(tail, max_length, acc <> @new_line <> escaped, byte_size(escaped))
    end
  end

  @doc """
  Decodes a quoted-printable encoded string.

  ## Examples

      Mail.Encoders.QuotedPrintable.decode("fa=C3=A7ade")
      "façade"
  """
  @spec decode(binary) :: binary
  def decode(string, acc \\ <<>>)

  def decode(<<>>, acc), do: acc

  # Soft line break - remove it
  def decode(<<?=, ?\r, ?\n, tail::binary>>, acc) do
    decode(tail, acc)
  end

  # Soft line break (bare LF, common in LF-only emails)
  def decode(<<?=, ?\n, tail::binary>>, acc) do
    decode(tail, acc)
  end

  # Encoded character =XX — valid hex digits
  def decode(<<?=, c1, c2, tail::binary>>, acc)
      when (c1 in ?0..?9 or c1 in ?A..?F or c1 in ?a..?f) and
             (c2 in ?0..?9 or c2 in ?A..?F or c2 in ?a..?f) do
    decode(tail, acc <> <<hex_val(c1) * 16 + hex_val(c2)>>)
  end

  # Encoded character =XX — invalid hex digits
  def decode(<<?=, c1, c2, tail::binary>>, acc) do
    decode(tail, acc <> "=" <> <<c1, c2>>)
  end

  # = followed by less than 2 characters (malformed, keep as-is)
  def decode(<<?=, rest::binary>>, acc) when byte_size(rest) < 2 do
    acc <> "=" <> rest
  end

  # Regular characters - process entire chunk until next =
  def decode(string, acc) do
    case :binary.match(string, "=") do
      {pos, 1} ->
        # Found = at position pos, take everything before it
        <<chunk::binary-size(pos), rest::binary>> = string
        decode(rest, acc <> chunk)

      :nomatch ->
        # No = found, append entire remaining string
        acc <> string
    end
  end

  defp hex_val(c) when c >= ?0 and c <= ?9, do: c - ?0
  defp hex_val(c) when c >= ?A and c <= ?F, do: c - ?A + 10
  defp hex_val(c) when c >= ?a and c <= ?f, do: c - ?a + 10
end
