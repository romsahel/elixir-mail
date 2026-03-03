defmodule Mail.Parsers.RFC2822BinaryTest do
  use ExUnit.Case, async: true
  doctest Mail.Parsers.RFC2822Binary

  test "handler can skip parts based on size" do
    message =
      parse_email(
        """
        Subject: Test
        Content-Type: multipart/mixed; boundary=foo

        --foo
        Content-Type: text/plain

        Small part
        --foo
        Content-Type: text/plain

        This is a much larger part with lots of content that should be skipped
        --foo--
        """,
        parts_handler_fn: fn msg, opts ->
          if opts[:part_size] > 50 do
            {:skip, %{msg | body: "[Skipped]"}}
          else
            {:parse, msg}
          end
        end
      )

    assert length(message.parts) == 2
    [small_part, large_part] = message.parts

    assert small_part.body == "Small part"
    assert large_part.body == "[Skipped]"
  end

  test "handler can filter by content-type" do
    message =
      parse_email(
        """
        Subject: Test
        Content-Type: multipart/mixed; boundary=foo

        --foo
        Content-Type: text/plain

        Keep this
        --foo
        Content-Type: image/png

        Skip this
        --foo--
        """,
        parts_handler_fn: fn msg, _opts ->
          content_type = Mail.Message.get_content_type(msg) |> List.first()

          if String.starts_with?(content_type, "image/") do
            {:skip, %{msg | body: "[Image removed]"}}
          else
            {:parse, msg}
          end
        end
      )

    assert length(message.parts) == 2
    [text_part, image_part] = message.parts

    assert text_part.body == "Keep this"
    assert image_part.body == "[Image removed]"
  end

  test "handler receives correct part info" do
    collected_info = Agent.start_link(fn -> [] end)
    {:ok, pid} = collected_info

    parse_email(
      """
      Subject: Test
      Content-Type: multipart/mixed; boundary=foo

      --foo
      Content-Type: text/plain

      Part 1
      --foo
      Content-Type: text/plain

      Part 2
      --foo--
      """,
      parts_handler_fn: fn msg, opts ->
        Agent.update(pid, fn list ->
          [%{index: opts[:part_index], size: opts[:part_size]} | list]
        end)

        {:parse, msg}
      end
    )

    infos = Agent.get(pid, & &1) |> Enum.reverse()
    Agent.stop(pid)

    assert length(infos) == 2

    [info1, info2] = infos
    assert info1.index == 0
    assert info2.index == 1
    assert is_integer(info1.size)
  end

  test "handler with nested multipart" do
    message =
      parse_email(
        """
        Subject: Test
        Content-Type: multipart/mixed; boundary=outer

        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain

        Inner text
        --inner--
        --outer
        Content-Type: application/pdf

        Large PDF content
        --outer--
        """,
        parts_handler_fn: fn msg, _opts ->
          content_type = Mail.Message.get_content_type(msg) |> List.first()

          if String.starts_with?(content_type, "application/") do
            {:skip, %{msg | body: "[Binary skipped]"}}
          else
            {:parse, msg}
          end
        end
      )

    assert length(message.parts) == 2
    [nested_part, pdf_part] = message.parts

    # Nested multipart should still be parsed normally
    assert nested_part.multipart == true
    assert length(nested_part.parts) == 1

    # PDF should be skipped
    assert pdf_part.body == "[Binary skipped]"
  end

  # ============================================================================
  # Comparison with RFC2822 Parser
  # ============================================================================

  test "produces same output as RFC2822 for simple message" do
    email =
      convert_crlf("""
      Subject: Test
      From: me@example.com

      Body text
      """)

    binary_result = Mail.Parsers.RFC2822Binary.parse(email)
    original_result = Mail.Parsers.RFC2822.parse(email)

    assert binary_result.headers == original_result.headers
    assert binary_result.body == original_result.body
    assert binary_result.multipart == original_result.multipart
  end

  test "produces same output as RFC2822 for multipart message" do
    email =
      convert_crlf("""
      Subject: Test
      Content-Type: multipart/mixed; boundary=foo

      --foo
      Content-Type: text/plain

      Part 1
      --foo
      Content-Type: text/html

      <p>Part 2</p>
      --foo--
      """)

    binary_result = Mail.Parsers.RFC2822Binary.parse(email)
    original_result = Mail.Parsers.RFC2822.parse(email)

    assert binary_result.headers == original_result.headers
    assert binary_result.multipart == original_result.multipart
    assert length(binary_result.parts) == length(original_result.parts)

    Enum.zip(binary_result.parts, original_result.parts)
    |> Enum.each(fn {bp, op} ->
      assert bp.headers == op.headers
      assert bp.body == op.body
    end)
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp parse_email(email, opts) do
    email
    |> convert_crlf()
    |> Mail.Parsers.RFC2822Binary.parse(opts)
  end

  defp convert_crlf(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\n", "\r\n")
  end
end
