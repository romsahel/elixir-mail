defmodule Mail.Parsers.RFC2822Stream.State do
  @moduledoc false

  defstruct [
    # Parser phase: :root_headers | :root_body | :preamble | :part_headers | :part_body | :skip_body | :epilogue
    phase: :root_headers,
    opts: [],

    # Root message context
    root_headers: [],
    root_current_header: nil,
    root_message: nil,
    root_body_buffer: [],

    # Multipart context
    multipart: %{
      boundary: nil,
      start_boundary: nil,
      end_boundary: nil,
      parts: [],
      part_index: 0
    },

    # Current part context
    part: %{
      headers: [],
      current_header: nil,
      pending_message: nil,
      body_buffer: []
    },

    # Stack of parent multipart contexts
    stack: []
  ]

  @doc """
  Creates a new State struct.
  """
  def new(opts) do
    %__MODULE__{
      phase: :root_headers,
      opts: opts
    }
  end

  @doc """
  Resets the part context for parsing the next part.
  """
  def reset_part(state) do
    %{
      state
      | part: %{
          state.part
          | headers: [],
            current_header: nil,
            pending_message: nil,
            body_buffer: []
        }
    }
  end

  @doc """
  Initializes multipart context with the given boundary.
  """
  def init_multipart(state, boundary) do
    %{
      state
      | multipart: %{
          state.multipart
          | boundary: boundary,
            start_boundary: "--" <> boundary,
            end_boundary: "--" <> boundary <> "--",
            parts: [],
            part_index: 0
        }
    }
  end
end
