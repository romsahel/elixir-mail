defmodule Mail.Parsers.RFC2822StreamPartsHandlerTest do
  use ExUnit.Case, async: true

  doctest Mail.Parsers.RFC2822

  describe "parts_handler_fn" do
    @multi_part_message """
    To: Test User <user@example.com>, Other User <other@example.com>
    CC: The Dude <dude@example.com>, Batman <batman@example.com>
    From: Me <me@example.com>
    Subject: Test email
    Mime-Version: 1.0
    Content-Type: multipart/alternative; boundary=foobar

    This is a multi-part message in MIME format
    --foobar
    Content-Type: text/plain

    This is some text

    --foobar
    Content-Type: text/html

    <h1>This is some HTML</h1>

    --foobar
    x-my-header: no body!

    --foobar--
    """

    test "handler returning :parse parses parts normally" do
      message =
        parse_email(
          @multi_part_message,
          parts_handler_fn: fn message, _opts ->
            {:parse, message}
          end
        )

      assert message.body == nil
      [text_part, html_part, headers_only_part] = message.parts

      assert text_part.headers["content-type"] == ["text/plain", {"charset", "us-ascii"}]
      assert text_part.body == "This is some text"

      assert html_part.headers["content-type"] == ["text/html", {"charset", "us-ascii"}]
      assert html_part.body == "<h1>This is some HTML</h1>"

      assert headers_only_part.headers["x-my-header"] == "no body!"
      assert headers_only_part.body == nil
    end

    test "handler returning custom message with skipped body" do
      message =
        parse_email(
          @multi_part_message,
          parts_handler_fn: fn message, _opts ->
            {:skip, Map.put(message, :body, "[Headers only - body skipped]")}
          end
        )

      assert message.body == nil
      [text_part, html_part, headers_only_part] = message.parts

      # Headers are still parsed
      assert text_part.headers["content-type"] == ["text/plain", {"charset", "us-ascii"}]
      # Body is replaced with placeholder
      assert text_part.body =~ "[Headers only - body skipped]"

      assert html_part.headers["content-type"] == ["text/html", {"charset", "us-ascii"}]
      assert html_part.body =~ "[Headers only - body skipped]"

      assert headers_only_part.headers["x-my-header"] == "no body!"
      assert headers_only_part.body == "[Headers only - body skipped]"
    end

    test "handler returning custom message" do
      message =
        parse_email(
          @multi_part_message,
          parts_handler_fn: fn message, opts ->
            part_index = opts[:part_index]

            new_message = %Mail.Message{
              body: "Custom body for part #{part_index}",
              headers: Map.put(message.headers, "x-custom", "true")
            }

            {:skip, new_message}
          end
        )

      assert message.body == nil
      [text_part, html_part, headers_only_part] = message.parts

      assert text_part.body == "Custom body for part 0"
      assert text_part.headers["x-custom"] == "true"
      assert text_part.headers["content-type"] == ["text/plain", {"charset", "us-ascii"}]

      assert html_part.body == "Custom body for part 1"
      assert html_part.headers["x-custom"] == "true"

      assert headers_only_part.body == "Custom body for part 2"
      assert headers_only_part.headers["x-custom"] == "true"
    end

    test "handler can access message and conditionally skip based on content-type" do
      message =
        parse_email(
          @multi_part_message,
          parts_handler_fn: fn message, _opts ->
            content_type = message.headers["content-type"]
            # Skip HTML parts
            if List.first(content_type || []) == "text/html" do
              {:skip, Map.put(message, :body, "[Headers only - body skipped]")}
            else
              {:parse, message}
            end
          end
        )

      [text_part, html_part, headers_only_part] = message.parts

      # Text part should be parsed
      assert text_part.body == "This is some text"

      # HTML part should be skipped
      assert html_part.body =~ "[Headers only - body skipped]"

      # Headers-only part should be parsed
      assert headers_only_part.body == nil
    end

    test "handler with nested parts correctly indexes" do
      nested_message = """
      Content-Type: multipart/mixed; boundary=outer

      --outer
      Content-Type: text/plain

      Outer text 1

      --outer
      Content-Type: multipart/alternative; boundary=inner

      --inner
      Content-Type: text/plain

      Inner text

      --inner
      Content-Type: text/html

      Inner html

      --inner--
      --outer
      Content-Type: text/plain

      Outer text 2

      --outer--
      """

      message =
        parse_email(
          nested_message,
          parts_handler_fn: fn
            %{multipart: true} = message, _opts ->
              {:parse, message}

            message, opts ->
              {:skip, %{message | body: "Custom body for part #{opts[:part_index]}"}}
          end
        )

      [text_part, %{parts: [inner_text_part, inner_html_part]}, text_part2] = message.parts

      assert text_part.body == "Custom body for part 0"

      assert inner_text_part.body == "Custom body for part 0"
      assert inner_html_part.body == "Custom body for part 1"

      assert text_part2.body == "Custom body for part 2"
    end

    test "handles parent boundary appearing in nested part body (boundary collision)" do
      nested_message = """
      Content-Type: multipart/mixed; boundary=outer

      --outer
      Content-Type: multipart/alternative; boundary=inner

      --inner
      Content-Type: text/plain

      This text contains what looks like parent boundaries:
      --outer
      This should be part of the body, not a boundary.
      --outer--
      Still in the body.

      --inner--
      --outer
      Content-Type: text/plain

      Part after nested

      --outer--
      """

      message =
        parse_email(
          nested_message,
          parts_handler_fn: fn message, _opts ->
            {:parse, message}
          end
        )

      [nested_part, text_part] = message.parts

      # The nested part should contain one inner part
      assert nested_part.multipart == true
      [inner_text_part] = nested_part.parts

      # The inner part's body should include the parent boundary markers as content
      assert inner_text_part.body ==
               """
               This text contains what looks like parent boundaries:
               --outer
               This should be part of the body, not a boundary.
               --outer--
               Still in the body.
               """
               |> String.trim()
               |> convert_crlf()

      # The outer level should still parse correctly
      assert text_part.body == "Part after nested"
    end
  end

  defp parse_email(email, opts),
    do: email |> convert_crlf() |> Mail.Parsers.RFC2822Stream.parse(opts)

  def convert_crlf(text), do: String.replace(text, "\n", "\r\n")
end
