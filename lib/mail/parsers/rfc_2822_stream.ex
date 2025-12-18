defmodule Mail.Parsers.RFC2822Stream do
  @moduledoc """
  Streaming parser for RFC2822 email messages.

  Processes email content line-by-line using a single-pass state machine, efficient for large
  multipart messages.
  """
  alias Mail.Parsers.RFC2822
  alias Mail.Parsers.RFC2822.PartsHandler
  alias Mail.Message

  defmodule StackEntry do
    @moduledoc false
    defstruct [:parent_message, :multipart_context]
  end

  alias Mail.Parsers.RFC2822Stream.State

  @doc """
  Parses an email into a `%Message{}` struct.

  Accepts a binary (for retrocompatibility) or an enumerable (stream) of lines.

  ## Options

    * `:charset_handler` - Function to handle charset decoding.
    * `:parts_handler_fn` - Callback invoked for each part of a multipart message,
      after its headers are parsed and before its body is read. See
      `Mail.Parsers.RFC2822.PartsHandler` for the full callback contract.
  """

  @spec parse(binary() | nonempty_maybe_improper_list() | Enumerable.t(), keyword()) ::
          Message.t()
  def parse(content, opts \\ []) do
    content
    |> to_stream()
    |> parse_stream(opts)
  end

  # Converts a binary or enumerable of lines into a stream of lines for retrocompatibility.
  # Lines are returned without line endings (trim_line_ending will handle any remaining \r\n)
  defp to_stream(content) when is_binary(content) do
    Stream.unfold(String.trim_trailing(content, "\r\n"), fn
      "" ->
        nil

      remaining ->
        case :binary.split(remaining, "\r\n") do
          [line, rest] -> {line, rest}
          [line] -> {line, ""}
        end
    end)
  end

  defp to_stream(content), do: content

  # ==============================================================================
  # Single-Pass State Machine
  #
  # States:
  #   :root_headers   - Parsing main message headers
  #   :root_body      - Collecting non-multipart message body
  #   :preamble       - Between root headers and first boundary (discarded)
  #   :part_headers   - Parsing a part's headers
  #   :part_body      - Collecting a part's body (when handler returns :parse)
  #   :skip_body      - Skipping a part's body (when handler returns Message)
  #   :epilogue       - After end boundary (discarded)
  # ==============================================================================

  defp parse_stream(stream, opts) do
    stream
    |> Stream.map(&trim_line_ending/1)
    |> Enum.reduce(State.new(opts), &process_line/2)
    |> finalize_parsing()
  end

  # Fast binary pattern matching for trimming \r\n, \n, or \r
  defp trim_line_ending(line) when is_binary(line), do: trim_line_ending(byte_size(line), line)

  defp trim_line_ending(byte_size, line)
       when byte_size >= 2 and binary_part(line, byte_size - 2, 2) == "\r\n",
       do: binary_part(line, 0, byte_size - 2)

  defp trim_line_ending(byte_size, line)
       when byte_size >= 1 and binary_part(line, byte_size - 1, 1) == "\n",
       do: binary_part(line, 0, byte_size - 1)

  defp trim_line_ending(byte_size, line)
       when byte_size >= 1 and binary_part(line, byte_size - 1, 1) == "\r",
       do: binary_part(line, 0, byte_size - 1)

  defp trim_line_ending(_, line), do: line

  # ==============================================================================
  # Line Processing Dispatch
  # ==============================================================================

  defp process_line(line, %State{phase: :root_headers} = state),
    do: process_root_header(line, state)

  defp process_line(line, %State{phase: :root_body} = state), do: process_root_body(line, state)
  defp process_line(line, %State{phase: :preamble} = state), do: process_preamble(line, state)

  defp process_line(line, %State{phase: :part_headers} = state),
    do: process_part_header(line, state)

  defp process_line(line, %State{phase: :part_body} = state), do: process_part_body(line, state)
  defp process_line(line, %State{phase: :skip_body} = state), do: process_skip_body(line, state)
  defp process_line(_line, %State{phase: :epilogue} = state), do: state

  # ==============================================================================
  # Root Headers State
  # ==============================================================================

  defp process_root_header("", state) do
    # Empty line marks end of headers
    finalize_headers(state.root_headers, state.root_current_header)
    |> build_message(state.opts)
    |> case do
      %Message{multipart: true} = message -> transition_to_preamble(state, message)
      %Message{multipart: false} = message -> transition_to_root_body(state, message)
    end
  end

  defp process_root_header(<<first_char, _::binary>> = line, state)
       when first_char in [?\s, ?\t] do
    # Folded header continuation
    current = if state.root_current_header, do: state.root_current_header <> line, else: line
    %{state | root_current_header: current}
  end

  defp process_root_header(line, %State{root_current_header: nil} = state) do
    # New header line (no current header to finalize)
    %{state | root_current_header: line}
  end

  defp process_root_header(
         line,
         %State{root_current_header: current, root_headers: headers} = state
       ) do
    # New header line (finalize current header first)
    %{state | root_headers: [current | headers], root_current_header: line}
  end

  # ==============================================================================
  # Root Body State (non-multipart)
  # ==============================================================================

  defp process_root_body(line, state) do
    %{state | root_body_buffer: [line | state.root_body_buffer]}
  end

  # ==============================================================================
  # Preamble State
  # ==============================================================================

  defp process_preamble(line, state) do
    case check_boundary(line, state) do
      {:start_boundary, _} ->
        %{
          state
          | phase: :part_headers,
            part: %{state.part | headers: [], current_header: nil}
        }

      {:end_boundary, _} ->
        %{state | phase: :epilogue}

      # Accumulate preamble content for fallback body (if no parts found)
      :none ->
        %{state | root_body_buffer: [line | state.root_body_buffer]}
    end
  end

  # ==============================================================================
  # Part Headers State
  # ==============================================================================

  defp process_part_header("", state) do
    # Empty line marks end of part headers
    finish_part_headers(state)
  end

  defp process_part_header(line, state) do
    case check_boundary(line, state) do
      {:start_boundary, _} ->
        state
        |> finish_part_headers()
        |> finalize_part()
        # The line detected as boundary is for the NEXT part, needed initialization
        |> Map.put(:phase, :part_headers)

      {:end_boundary, _} ->
        state
        |> finish_part_headers()
        |> finalize_part()
        |> finalize_multipart_level()

      :none ->
        # Header line
        {new_headers, new_current} =
          accumulate_header(line, state.part.headers, state.part.current_header)

        %{state | part: %{state.part | headers: new_headers, current_header: new_current}}
    end
  end

  defp finish_part_headers(state) do
    finalize_headers(state.part.headers, state.part.current_header)
    |> build_message(state.opts)
    |> PartsHandler.invoke(state.multipart.part_index, state.opts)
    |> case do
      {:parse, %Message{multipart: true} = message} ->
        # Nested multipart - push current context to stack
        push_multipart_context(state, message)

      {:parse, %Message{multipart: false} = message} ->
        transition_to_part_body(state, message)

      {:skip, message} ->
        transition_to_skip_body(state, message)
    end
  end

  # ==============================================================================
  # Part Body State
  # ==============================================================================

  defp process_part_body(line, state) do
    case check_boundary(line, state) do
      {:start_boundary, _} ->
        # End of this part, start of next
        state
        |> finalize_part()
        |> reset_part_state()

      {:end_boundary, _} ->
        # End of this part and end of multipart
        state
        |> finalize_part()
        |> finalize_multipart_level()

      :none ->
        # Accumulate body line
        %{state | part: %{state.part | body_buffer: [line | state.part.body_buffer]}}
    end
  end

  # ==============================================================================
  # Skip Body State (handler returned custom message or awaiting boundary after nested)
  # ==============================================================================

  defp process_skip_body(line, state) do
    case check_boundary(line, state) do
      {:start_boundary, _} ->
        # End of skipped part (if any), start of next
        state
        |> finalize_skipped_part()
        |> reset_part_state()

      {:end_boundary, _} ->
        # End of skipped part (if any) and end of multipart
        state
        |> finalize_skipped_part()
        |> finalize_multipart_level()

      :none ->
        # Discard body line
        state
    end
  end

  # ==============================================================================
  # Nested Multipart Support
  # ==============================================================================

  defp push_multipart_context(state, message) do
    boundary = Mail.Proplist.get(message.headers["content-type"], "boundary")

    # Store parent message and current multipart context in stack
    entry = %StackEntry{
      parent_message: message,
      multipart_context: state.multipart
    }

    state
    |> Map.put(:phase, :preamble)
    |> Map.put(:stack, [entry | state.stack])
    |> State.init_multipart(boundary)
    |> State.reset_part()
  end

  defp finalize_multipart_level(state) do
    # Current level parts are done.
    all_parts = Enum.reverse(state.multipart.parts)

    case state.stack do
      [] ->
        # Top level - done
        %{state | phase: :epilogue, multipart: %{state.multipart | parts: all_parts}}

      [%StackEntry{} = parent | rest_stack] ->
        # Pop from stack, create nested message with parts
        nested_message = Map.put(parent.parent_message, :parts, all_parts)

        # Go to skip_body state to await next boundary.
        # Restore parent multipart context, adding the nested message we just built.
        %{
          state
          | phase: :skip_body,
            stack: rest_stack,
            multipart: %{
              parent.multipart_context
              | parts: [nested_message | parent.multipart_context.parts],
                part_index: parent.multipart_context.part_index + 1
            },
            # part.pending_message is nil because we just finished strict parsing of a part
            part: %{
              state.part
              | pending_message: nil
            }
        }
    end
  end

  # ==============================================================================
  # Part Finalization Logic
  # ==============================================================================

  defp finalize_part(state) do
    part = decode_body(state.part.pending_message, state.part.body_buffer, state.opts)

    %{
      state
      | multipart: %{
          state.multipart
          | parts: [part | state.multipart.parts],
            part_index: state.multipart.part_index + 1
        }
    }
  end

  defp finalize_skipped_part(%State{part: %{pending_message: nil}} = state) do
    # Already added (nested multipart case)
    state
  end

  defp finalize_skipped_part(%State{part: %{pending_message: message}} = state) do
    %{
      state
      | multipart: %{
          state.multipart
          | parts: [message | state.multipart.parts],
            part_index: state.multipart.part_index + 1
        },
        part: %{state.part | pending_message: nil}
    }
  end

  defp reset_part_state(state) do
    state
    |> Map.put(:phase, :part_headers)
    |> State.reset_part()
  end

  # ==============================================================================
  # Finalization
  #
  # Handles graceful termination when stream ends unexpectedly in any phase.
  # Each clause handles a specific edge case based on parser state.
  # ==============================================================================

  defp finalize_parsing(%State{phase: :root_headers} = state) do
    # Edge case: Stream ended before body started (email with only headers)
    # Action: Build message from accumulated headers with empty body
    headers = finalize_headers(state.root_headers, state.root_current_header)

    headers
    |> build_message(state.opts)
    |> Map.put(:body, "")
  end

  defp finalize_parsing(%State{phase: :root_body} = state) do
    # Normal case: Non-multipart message with body
    # Action: Decode accumulated body buffer into message.body
    state.root_message
    |> put_decoded_body(state.root_body_buffer, state.opts)
  end

  defp finalize_parsing(
         %State{phase: :preamble, multipart: %{parts: []}, root_body_buffer: []} = state
       ) do
    # Edge case: Multipart declared in headers but no boundary found, no preamble
    # Action: Return message with empty parts list and empty body
    state.root_message
    |> Map.put(:parts, [])
    |> Map.put(:body, "")
  end

  defp finalize_parsing(%State{phase: :preamble, multipart: %{parts: []}} = state) do
    # Edge case: Multipart declared but no boundary found, preamble exists
    # Action: Treat preamble as regular body, demote to non-multipart
    state.root_message
    |> put_decoded_body(state.root_body_buffer, state.opts)
    |> Map.put(:multipart, false)
  end

  defp finalize_parsing(%State{phase: :epilogue, multipart: %{parts: parts}} = state) do
    # Normal case: Multipart message ended cleanly and reached the final --boundary--
    # Action: Build message with all collected parts
    Map.put(state.root_message, :parts, parts)
  end

  defp finalize_parsing(
         %State{phase: :part_headers, part: %{headers: [], current_header: nil}} = state
       ) do
    # Edge case: Stream ended at a trailing boundary with no content after
    # Action: Don't add empty part, just return collected parts
    build_multipart_message(state)
  end

  defp finalize_parsing(%State{phase: :part_headers} = state) do
    # Edge case: Stream ended mid-way through parsing part headers
    # Action: Finish incomplete headers and add partial part
    state
    |> finish_part_headers()
    |> case do
      %State{phase: :part_body} = state -> finalize_part(state)
      state -> finalize_skipped_part(state)
    end
    |> build_multipart_message()
  end

  defp finalize_parsing(%State{phase: :part_body} = state) do
    # Edge case: Stream ended while collecting part body
    # Action: Finalize part with whatever body was collected so far
    state
    |> finalize_part()
    |> build_multipart_message()
  end

  defp finalize_parsing(%State{phase: :skip_body} = state) do
    # Edge case: Stream ended while handler was skipping part body
    # Action: Finalize the skipped part (already has custom message from handler)
    state
    |> finalize_skipped_part()
    |> build_multipart_message()
  end

  # ==============================================================================
  # Helpers
  # ==============================================================================

  defp check_boundary(line, %{multipart: multipart}) do
    cond do
      line == multipart.start_boundary -> {:start_boundary, line}
      line == multipart.end_boundary -> {:end_boundary, line}
      true -> :none
    end
  end

  defp finalize_headers(headers, current_header) do
    final = if current_header, do: [current_header | headers], else: headers
    Enum.reverse(final)
  end

  defp build_message(headers, opts) do
    %Message{}
    |> RFC2822.parse_headers(headers, opts)
    |> RFC2822.mark_multipart()
  end

  defp decode_body(message, buffer, opts) do
    case buffer do
      [] -> Map.put(message, :body, "")
      buffer -> put_decoded_body(message, buffer, opts)
    end
  end

  defp accumulate_header(<<first_char, _::binary>> = line, headers, current_header)
       when first_char in [?\s, ?\t] do
    # Continuation
    updated = if current_header, do: current_header <> line, else: line
    {headers, updated}
  end

  defp accumulate_header(line, headers, current_header) do
    # New header
    new_headers = if current_header, do: [current_header | headers], else: headers
    {new_headers, line}
  end

  defp build_multipart_message(%State{multipart: %{parts: parts}, root_message: root_message}) do
    parts
    |> Enum.reverse()
    |> then(&Map.put(root_message, :parts, &1))
  end

  defp put_decoded_body(%Message{} = message, buffer, opts) when is_list(buffer) do
    buffer
    |> Enum.reverse()
    |> Enum.join("\r\n")
    |> RFC2822.decode(message, opts)
    |> then(fn body ->
      Map.put(message, :body, body)
    end)
  end

  defp transition_to_root_body(state, message) do
    %{
      state
      | phase: :root_body,
        root_message: message,
        root_headers: [],
        root_current_header: nil
    }
  end

  defp transition_to_preamble(state, message) do
    boundary = Mail.Proplist.get(message.headers["content-type"], "boundary")

    state
    |> Map.put(:phase, :preamble)
    |> Map.put(:root_message, message)
    |> Map.put(:root_headers, [])
    |> Map.put(:root_current_header, nil)
    |> State.init_multipart(boundary)
  end

  defp transition_to_part_body(state, message) do
    %{
      state
      | phase: :part_body,
        part: %{
          state.part
          | headers: [],
            current_header: nil,
            pending_message: message,
            body_buffer: []
        }
    }
  end

  defp transition_to_skip_body(state, message) do
    %{
      state
      | phase: :skip_body,
        part: %{
          state.part
          | headers: [],
            current_header: nil,
            pending_message: message
        }
    }
  end
end
