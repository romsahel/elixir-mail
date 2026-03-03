defmodule Mail.Parsers.RFC2822Binary do
  alias Mail.Parsers.RFC2822
  alias Mail.Parsers.RFC2822.PartsHandler

  @moduledoc ~S"""
  RFC2822 Parser

  Will attempt to parse a valid RFC2822 message back into
  a `%Mail.Message{}` data model.

  ## Examples

      iex> message = \"""
      ...> To: user@example.com\r
      ...> From: me@example.com\r
      ...> Subject: Test Email\r
      ...> Content-Type: text/plain; foo=bar;\r
      ...>   baz=qux;\r
      ...> \r
      ...> This is the body!\r
      ...> It has more than one line\r
      ...> \"""
      iex> Mail.Parsers.RFC2822Binary.parse(message)
      %Mail.Message{body: "This is the body!\r\nIt has more than one line", headers: %{"to" => ["user@example.com"], "from" => "me@example.com", "subject" => "Test Email", "content-type" => ["text/plain", {"foo", "bar"}, {"baz", "qux"}]}}
  """

  @doc """
  Parses a RFC2822 message back into a `%Mail.Message{}` data model.

  ## Options

    * `:charset_handler` - A function that takes a charset and binary and returns a binary. Defaults to return the string as is.
    * `:headers_only` - Whether to parse only the headers. Defaults to false.
    * `:parts_handler_fn` - Callback invoked for each part of a multipart message,
      after its headers are parsed and before its body is read. Injects
      `opts[:part_index]` and `opts[:part_size]` (byte size of raw part content).
      See `Mail.Parsers.RFC2822.PartsHandler` for the full callback contract.
  """
  @spec parse(binary() | nonempty_maybe_improper_list(), keyword()) :: Mail.Message.t()
  def parse(content, opts \\ []) when is_binary(content) do
    content =
      if String.ends_with?(content, "\r\n"),
        do: binary_part(content, 0, byte_size(content) - 2),
        else: content

    parse_part(%{
      part_info: %{size: byte_size(content), start: 0, index: 0},
      body_content: content,
      call_handler: false,
      opts: opts
    })
  end

  defp parse_part(%{
         part_info: part_info,
         body_content: body_content,
         call_handler: call_handler,
         opts: opts
       }) do
    part_data = binary_part(body_content, part_info.start, part_info.size)
    {headers, body_offset, has_body} = extract_headers_and_body_offset(part_data)

    message =
      %Mail.Message{}
      |> RFC2822.parse_headers(headers, opts)
      |> RFC2822.mark_multipart()

    handler_result =
      if call_handler do
        opts_with_size = Keyword.put(opts, :part_size, part_info.size)
        PartsHandler.invoke(message, part_info.index, opts_with_size)
      else
        {:parse, message}
      end

    apply_handler_result(handler_result, %{
      has_body: has_body,
      body_offset: body_offset,
      part_data: part_data,
      opts: opts
    })
  end

  defp apply_handler_result({:skip, message}, _context) do
    message
  end

  defp apply_handler_result({:parse, message}, %{has_body: false}) do
    Map.put(message, :body, "")
  end

  defp apply_handler_result({:parse, message}, %{
         body_offset: body_offset,
         part_data: part_data,
         opts: opts
       }) do
    body_content =
      if body_offset < byte_size(part_data) do
        part_data
        |> binary_part(body_offset, byte_size(part_data) - body_offset)
        # Strip the trailing CRLF that belongs to the boundary delimiter per RFC 2046
        |> trim_line_ending()
      else
        ""
      end

    parse_body_binary(message, body_content, opts)
  end

  defp extract_headers_and_body_offset(content) do
    content
    |> Stream.unfold(fn remaining ->
      case remaining |> :binary.split("\n") do
        [""] -> nil
        [line, rest] -> {{line, byte_size(line) + 1}, rest}
        [line] -> {{line, byte_size(line)}, ""}
      end
    end)
    |> Stream.map(fn {line, size} -> {trim_line_ending(line), size} end)
    |> Enum.reduce_while({[], nil, 0, false}, &accumulate_headers/2)
    |> case do
      {headers, current_header, offset, false} ->
        # No empty line found - all content is headers, no body section
        headers = if current_header, do: [current_header | headers], else: headers
        {Enum.reverse(headers), offset, false}

      {headers, _current_header, offset, true} ->
        # Empty line found normally - there is a body section (even if empty)
        {headers, offset, true}
    end
  end

  # Empty line marks end of headers
  defp accumulate_headers({"", line_size}, {headers, current_header, offset, _found}) do
    final_headers = if current_header, do: [current_header | headers], else: headers
    {:halt, {Enum.reverse(final_headers), nil, offset + line_size, true}}
  end

  # Folded header (continuation line starts with space or tab)
  defp accumulate_headers(
         {<<first_char, _::binary>> = line, line_size},
         {headers, current_header, offset, found}
       )
       when first_char in [?\s, ?\t] do
    current_header = if current_header, do: current_header <> line, else: nil
    {:cont, {headers, current_header, offset + line_size, found}}
  end

  # New header line
  defp accumulate_headers({line, line_size}, {headers, current_header, offset, found}) do
    new_headers = if current_header, do: [current_header | headers], else: headers
    {:cont, {new_headers, line, offset + line_size, found}}
  end

  defp parse_body_binary(%Mail.Message{multipart: true} = message, body_content, opts) do
    content_type = message.headers["content-type"]
    boundary = Mail.Proplist.get(content_type, "boundary")
    part_ranges = extract_parts_ranges(body_content, boundary)

    parsed_parts =
      part_ranges
      |> Enum.with_index()
      |> Enum.map(fn {{start, size}, index} ->
        parse_part(%{
          part_info: %{size: size, start: start, index: index},
          body_content: body_content,
          call_handler: true,
          opts: opts
        })
      end)

    case parsed_parts do
      [] -> parse_body_binary(Map.put(message, :multipart, false), body_content, opts)
      _ -> Map.put(message, :parts, parsed_parts)
    end
  end

  # Empty body for non-multipart - set to empty string
  defp parse_body_binary(%Mail.Message{multipart: false} = message, "", _opts) do
    Map.put(message, :body, "")
  end

  # Empty body for multipart (shouldn't happen normally, but leave as nil)
  defp parse_body_binary(%Mail.Message{} = message, "", _opts) do
    message
  end

  # Simple (non-multipart) body
  defp parse_body_binary(%Mail.Message{} = message, body_content, opts) do
    # Normalize line endings without splitting into array
    normalized_body = String.replace(body_content, ~r/\r?\n/, "\r\n")
    decoded = RFC2822.decode(normalized_body, message, opts)
    Map.put(message, :body, decoded)
  end

  defp extract_parts_ranges(content, boundary) do
    start_boundary = "--" <> boundary
    end_boundary = "--" <> boundary <> "--"

    # Stream through content tracking byte offsets for boundaries
    content
    |> Stream.unfold(fn remaining ->
      case remaining |> :binary.split("\n") do
        [""] -> nil
        [line, rest] -> {{line, byte_size(line) + 1}, rest}
        [line] -> {{line, byte_size(line)}, ""}
      end
    end)
    |> Stream.map(fn {line, size} -> {trim_line_ending(line), size} end)
    |> Enum.reduce_while({[], 0, nil, nil}, fn {line, line_size}, {_, offset, _, _} = acc ->
      new_offset = offset + line_size
      accumulate_part_range({line, new_offset}, acc, start_boundary, end_boundary)
    end)
    |> extract_final_part_range(content)
    |> Enum.reverse()
  end

  # End boundary found: but no part was started
  defp accumulate_part_range(
         {line, new_offset},
         {ranges, _offset, _state, nil},
         _start_boundary,
         end_boundary
       )
       when line == end_boundary do
    {:halt, {ranges, new_offset, :done, nil}}
  end

  # End boundary found: append new [part_start -> offset] range
  defp accumulate_part_range(
         {line, new_offset},
         {ranges, offset, _state, part_start},
         _start_boundary,
         end_boundary
       )
       when line == end_boundary do
    ranges = [{part_start, offset - part_start} | ranges]
    {:halt, {ranges, new_offset, :done, nil}}
  end

  # Start boundary found: first boundary
  defp accumulate_part_range(
         {line, new_offset},
         {ranges, _offset, nil, _part_start},
         start_boundary,
         _end_boundary
       )
       when line == start_boundary do
    {:cont, {ranges, new_offset, :collecting, new_offset}}
  end

  # Start boundary found: subsequent boundary
  defp accumulate_part_range(
         {line, new_offset},
         {ranges, offset, _state, part_start},
         start_boundary,
         _end_boundary
       )
       when line == start_boundary do
    part_range = {part_start, offset - part_start}
    {:cont, {[part_range | ranges], new_offset, :collecting, new_offset}}
  end

  # Inside a part: just track offset
  defp accumulate_part_range(
         {_line, new_offset},
         {ranges, _offset, :collecting, part_start},
         _start_boundary,
         _end_boundary
       ) do
    {:cont, {ranges, new_offset, :collecting, part_start}}
  end

  # Before first boundary: ignore
  defp accumulate_part_range(
         {_line, new_offset},
         {ranges, _offset, state, part_start},
         _start_boundary,
         _end_boundary
       ) do
    {:cont, {ranges, new_offset, state, part_start}}
  end

  # Handle case where end boundary wasn't found (still :collecting)
  defp extract_final_part_range({ranges, _offset, :collecting, start}, content) do
    # Add final part from start to end of content (if it has content (not empty or just whitespace)
    part_size = byte_size(content) - start

    if part_size > 0 and contains_non_whitespace?(content, start, start + part_size) do
      [{start, part_size} | ranges]
    else
      ranges
    end
  end

  defp extract_final_part_range({ranges, _offset, _state, _start}, _content) do
    ranges
  end

  @whitespaces [?\s, ?\t, ?\r, ?\n]
  defp contains_non_whitespace?(content, pos, limit) when pos < limit do
    case :binary.at(content, pos) do
      char when char in @whitespaces -> contains_non_whitespace?(content, pos + 1, limit)
      _ -> true
    end
  end

  defp contains_non_whitespace?(_, _, _), do: false

  # Fast binary pattern matching for trimming \r\n, \n, or \r from the end of a line.
  # Called after splitting on "\n", so lines only ever end with "\r" (CRLF input) or
  # nothing (LF-only input). The \r\n and \n clauses handle edge cases defensively.
  defp trim_line_ending(line) when is_binary(line), do: trim_line_ending(byte_size(line), line)

  defp trim_line_ending(size, line)
       when size >= 2 and binary_part(line, size - 2, 2) == "\r\n",
       do: binary_part(line, 0, size - 2)

  defp trim_line_ending(size, line)
       when size >= 1 and binary_part(line, size - 1, 1) == "\n",
       do: binary_part(line, 0, size - 1)

  defp trim_line_ending(size, line)
       when size >= 1 and binary_part(line, size - 1, 1) == "\r",
       do: binary_part(line, 0, size - 1)

  defp trim_line_ending(_, line), do: line
end
