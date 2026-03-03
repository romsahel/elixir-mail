defmodule Mail.Parsers.RFC2822.PartsHandler do
  @moduledoc """
  Defines and invokes the `parts_handler_fn` callback used by RFC 2822 parsers.
  The handler is a 2-arity function passed as `parts_handler_fn` in parser opts:
      parts_handler_fn: fn message, opts -> ... end

  It is called **once per part**, after the part's headers have been parsed but
  **before** the body is read or decoded. The handler decides what to do with
  the part body.

  ### Arguments

  | Argument  | Type            | Description |
  |-----------|-----------------|-------------|
  | `message` | `%Mail.Message{}` | Part with headers fully parsed. Body is `nil` at this point. |
  | `opts`    | `keyword()`     | Options originally passed to `parse/2`, and extra opts depending on parser (see below). |

  #### Extra opts injected by the parsers

  | Key           | Type      | Available in         | Description |
  |---------------|-----------|----------------------|-------------|
  | `:part_index` | `integer` | both parsers         | 0-based index of this part within its multipart container. Resets to 0 for each nesting level. |
  | `:part_size`  | `integer` | binary parser only   | Raw byte size of the part content (headers + body). Useful for skipping large attachments without reading them. |

  ### Return values

  | Return value          | Meaning |
  |-----------------------|---------|
  | `{:parse, message}`   | Parse the body normally and decode it. Use the returned `message` as the base (allows modifying headers before body parsing). |
  | `{:skip, message}`    | Skip body parsing entirely. The returned `message` is used as-is — set `:body` to whatever you want (e.g., `nil`, `""`, or a placeholder). |

  ## Examples

  ### Filter by content-type or parts size

      parts_handler_fn: fn message, _opts ->
        content_type = List.first(Message.get_content_type(message) || [])
        if content_type in @content_types_to_parse or part_info.size < @attachment_max_bytes_size do
          {:parse, message}
        else
          {:skip, %{message | body: "[image removed]"}}
        end
      end

  ### Annotate parts with their index

      parts_handler_fn: fn message, opts ->
        {:parse, put_in(message.headers["x-part-index"], opts[:part_index])}
      end

  """

  alias Mail.Message

  @doc false
  def invoke(message, part_index, opts) do
    with {:handler_fn, parts_handler_fn} when is_function(parts_handler_fn, 2) <-
           {:handler_fn, Keyword.get(opts, :parts_handler_fn)},
         handler_opts = Keyword.put(opts, :part_index, part_index),
         {:result, {action, %Message{} = message}} when action in [:parse, :skip] <-
           {:result, parts_handler_fn.(message, handler_opts)} do
      {action, message}
    else
      {:handler_fn, nil} ->
        {:parse, message}

      {:handler_fn, _} ->
        raise ArgumentError, "parts_handler_fn must be a function that accepts (message, opts)"

      {:result, invalid_result} ->
        raise ArgumentError,
              "parts_handler_fn must return {:parse, message} or {:skip, message}. Got: #{inspect(invalid_result)}"
    end
  end
end
