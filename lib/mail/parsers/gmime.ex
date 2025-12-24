defmodule Mail.Parsers.GMime do
  @moduledoc """
  High-performance RFC 2822 email parser using GMime C library.

  This parser provides two parsing modes:
  - `parse_stream/2` - Parse email from file (recommended for large files)
  - `parse_string/2` - Parse email from string

  ## Examples

      # Parse from file
      {:ok, message} = Mail.Parsers.GMime.parse_stream("email.eml")

      # Parse from string
      email_content = File.read!("email.eml")
      {:ok, message} = Mail.Parsers.GMime.parse_string(email_content)

      # Use with Mail.parse/2
      message = Mail.parse(email_content, Mail.Parsers.GMime)

  ## Requirements

  Requires GMime 3.0+ to be installed:
  - Ubuntu/Debian: `sudo apt-get install libgmime-3.0-dev`
  - macOS: `brew install gmime`
  """

  alias Mail.Parsers.GMime.NIF

  @type parse_result :: {:ok, Mail.Message.t()} | {:error, term()}

  @doc """
  Parse email from a file path.

  This is the recommended method for large emails as it uses streaming
  and doesn't load the entire file into memory.

  ## Options

  - `:charset_handler` - Function for custom charset conversion (not yet implemented)
  - `:attachment_handler` - Function for streaming attachments (not yet implemented)

  ## Examples

      {:ok, message} = Mail.Parsers.GMime.parse_stream("/path/to/email.eml")

  """
  @spec parse_stream(Path.t(), keyword()) :: parse_result()
  def parse_stream(file_path, opts \\ []) when is_binary(file_path) do
    case NIF.parse_stream_nif(file_path, opts) do
      {:ok, message} -> {:ok, post_process_message(message, opts)}
      error -> error
    end
  end

  @doc """
  Parse email from a binary string.

  ## Options

  - `:charset_handler` - Function for custom charset conversion (not yet implemented)

  ## Examples

      email = "To: user@example.com\\r\\nFrom: me@example.com\\r\\n\\r\\nBody"
      {:ok, message} = Mail.Parsers.GMime.parse_string(email)

  """
  @spec parse_string(binary(), keyword()) :: parse_result()
  def parse_string(email_content, opts \\ []) when is_binary(email_content) do
    case NIF.parse_string_nif(email_content, opts) do
      {:ok, message} -> {:ok, post_process_message(message, opts)}
      error -> error
    end
  end

  # Post-process the parsed message to match RFC2822 behavior exactly
  defp post_process_message(%Mail.Message{} = message, opts) do
    message
    |> post_process_headers(opts)
    |> post_process_body()
    |> post_process_parts(opts)
  end

  # Process headers for RFC2822 compatibility
  defp post_process_headers(%Mail.Message{headers: headers} = message, opts) do
    headers =
      headers
      |> post_process_date_header(opts)
      |> post_process_content_disposition_header(opts)
      |> post_process_received_header(opts)
      |> post_process_content_type_header(opts)
      |> post_process_address_headers(opts)

    %{message | headers: headers}
  end

  # Parse address headers (from, to, cc, reply-to) into structured format
  defp post_process_address_headers(headers, opts) do
    address_headers = ["from", "to", "cc", "reply-to"]

    Enum.reduce(address_headers, headers, fn header_name, acc_headers ->
      post_process_address_header(acc_headers, header_name, opts)
    end)
  end

  defp post_process_address_header(headers, header_name, opts) do
    case Map.get(headers, header_name) do
      nil ->
        headers

      value when is_binary(value) ->
        # Reconstruct header line and parse with RFC2822
        {_key, parsed_value} =
          Mail.Parsers.RFC2822.parse_header("#{header_name}: #{value}", opts)

        Map.put(headers, header_name, parsed_value)

      _already_parsed ->
        # Already in structured format
        headers
    end
  end

  # Parse date header into DateTime
  defp post_process_date_header(headers, _opts) do
    case Map.get(headers, "date") do
      nil ->
        headers

      date_string when is_binary(date_string) ->
        Map.put(headers, "date", Mail.Parsers.RFC2822.to_datetime(date_string))

      %DateTime{} = datetime ->
        # Already parsed
        Map.put(headers, "date", datetime)
    end
  end

  # Parse content-disposition into structured format
  defp post_process_content_disposition_header(headers, opts) do
    case Map.get(headers, "content-disposition") do
      nil ->
        headers

      value when is_binary(value) ->
        # Reconstruct header line and parse with RFC2822
        {_key, parsed_value} =
          Mail.Parsers.RFC2822.parse_header("content-disposition: #{value}", opts)

        Map.put(headers, "content-disposition", parsed_value)

      _already_parsed ->
        # Already in structured format
        headers
    end
  end

  # Parse received header into structured format
  defp post_process_received_header(headers, opts) do
    case Map.get(headers, "received") do
      nil ->
        headers

      values when is_list(values) ->
        # Process each received header
        parsed_values =
          Enum.map(values, fn
            value when is_binary(value) ->
              {_key, parsed_value} = Mail.Parsers.RFC2822.parse_header("received: #{value}", opts)
              parsed_value

            already_parsed ->
              already_parsed
          end)

        Map.put(headers, "received", parsed_values)

      value when is_binary(value) ->
        # Single received header
        {_key, parsed_value} = Mail.Parsers.RFC2822.parse_header("received: #{value}", opts)
        Map.put(headers, "received", [parsed_value])

      _already_parsed ->
        headers
    end
  end

  # Add default charset to content-type if missing
  # RFC2822 only adds charset when there are NO parameters at all
  defp post_process_content_type_header(headers, _opts) do
    case Map.get(headers, "content-type") do
      nil ->
        headers

      [content_type] when is_binary(content_type) ->
        # Content-Type with no parameters - add default charset
        Map.put(headers, "content-type", [content_type, {"charset", "us-ascii"}])

      [_content_type | _params] ->
        # Already has parameters, don't add charset
        headers

      _other ->
        headers
    end
  end

  # Process body: trim trailing newlines and convert empty to nil
  defp post_process_body(%Mail.Message{body: body, multipart: false} = message)
       when is_binary(body) do
    processed_body =
      body
      |> String.trim_trailing()
      |> case do
        "" -> nil
        trimmed -> trimmed
      end

    %{message | body: processed_body}
  end

  # Special case: multipart with no parts (edge case where content-type says multipart but no actual parts)
  # In this case, process the body like a regular message
  defp post_process_body(%Mail.Message{body: body, multipart: true, parts: []} = message)
       when is_binary(body) do
    processed_body =
      body
      |> String.trim_trailing()
      |> case do
        "" -> nil
        trimmed -> trimmed
      end

    %{message | body: processed_body}
  end

  defp post_process_body(message), do: message

  # Recursively process parts
  defp post_process_parts(%Mail.Message{parts: parts} = message, opts) when is_list(parts) do
    processed_parts = Enum.map(parts, &post_process_message(&1, opts))
    %{message | parts: processed_parts}
  end

  defp post_process_parts(message, _opts), do: message

  @doc """
  Parse email content (binary or enumerable).

  This is the main entry point called by `Mail.parse/2`.
  Compatible with the existing parser interface.

  ## Examples

      # Parse from binary
      Mail.Parsers.GMime.parse(email_string)

      # Use as custom parser
      Mail.parse(email_string, Mail.Parsers.GMime)

  """
  @spec parse(binary() | Enumerable.t(), keyword()) :: Mail.Message.t()
  def parse(content, opts \\ [])

  def parse(content, opts) when is_binary(content) do
    case parse_string(content, opts) do
      {:ok, message} -> message
      {:error, reason} -> raise "Failed to parse email: #{inspect(reason)}"
    end
  end

  def parse(content, _opts) when is_list(content) do
    # Convert list to binary
    content
    |> Enum.join("\r\n")
    |> parse()
  end

  def parse(content, _opts) do
    # Handle streams/enumerables by converting to binary
    content
    |> Enum.to_list()
    |> parse()
  end
end
