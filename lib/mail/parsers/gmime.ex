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
    NIF.parse_stream_nif(file_path, opts)
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
    NIF.parse_string_nif(email_content, opts)
  end

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
