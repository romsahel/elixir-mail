#!/usr/bin/env elixir
# Compares Mail.Parsers.RFC2822 (ground truth) against RFC2822Binary and RFC2822Stream
# using .eml files from the eml/ directory.
#
# Usage:
#   mix run scripts/compare_parsers.exs
#   mix run scripts/compare_parsers.exs path/to/folder

defmodule ParserComparison do
  @parsers [
    {Mail.Parsers.RFC2822Binary, "RFC2822Binary"},
    {Mail.Parsers.RFC2822Stream, "RFC2822Stream"}
  ]

  @tmp_dir "tmp/parser_renders"

  defp parse_args(args) do
    {flags, paths} = Enum.split_with(args, &String.starts_with?(&1, "--"))

    opts =
      Enum.flat_map(flags, fn
        "--save-renders" -> [save_renders: true]
        other -> IO.puts("Unknown flag: #{other}") && []
      end)

    {opts, paths}
  end

  def run(args) do
    {opts, extra_files} = parse_args(args)
    save_renders = Keyword.get(opts, :save_renders, false)

    eml_dir = Path.join(File.cwd!(), "eml")
    files = walk_files_in_paths(if extra_files == [], do: [eml_dir], else: extra_files)

    if files == [] do
      IO.puts("No .eml files found in #{eml_dir}")
      System.halt(1)
    end

    if save_renders do
      File.rm_rf!(@tmp_dir)
      File.mkdir_p!(@tmp_dir)
    end

    IO.puts("Ground truth: Mail.Parsers.RFC2822")
    IO.puts("Comparing against: #{Enum.map_join(@parsers, ", ", &elem(&1, 1))}")
    IO.puts("Files: #{length(files)}")
    if save_renders, do: IO.puts("Renders saved to: #{@tmp_dir}/")
    IO.puts(String.duplicate("=", 80))

    results = run_comparisons(files, save_renders)

    IO.puts("")
    IO.puts(String.duplicate("=", 80))

    results = Enum.reverse(results)
    failures = Enum.filter(results, fn {_, diffs} -> diffs != [] end)
    passes = length(results) - length(failures)

    IO.puts("\nResults: #{passes}/#{length(results)} passed\n")

    if failures == [] do
      IO.puts("All parsers produce identical output to the ground truth.")
    else
      IO.puts("#{length(failures)} failure(s):\n")
      print_failures(failures)
    end
  end

  defp run_comparisons(files, save_renders) do
    total = length(files)

    Enum.reduce(files, {[], {0, 0}}, fn path, {acc, {passes, fails}} ->
      content = read_eml!(path)
      diffs = run_comparison(Path.basename(path), content, save_renders)

      {passes, fails} =
        if diffs == [],
          do: {passes + 1, fails},
          else: {passes, fails + 1}

      done = passes + fails

      line =
        "[#{String.pad_leading("#{done}", String.length("#{total}"))} / #{total}]" <>
          " #{String.pad_leading("#{round(done / total * 100)}", 3)}%" <>
          "  PASS: #{passes}  FAIL: #{fails}"

      IO.write("\r#{line}")

      {[{path, diffs} | acc], {passes, fails}}
    end)
    |> elem(0)
  end

  defp run_comparison(name, content, save_renders) do
    stem = Path.rootname(name)

    base = safe_parse(Mail.Parsers.RFC2822, content)
    base_rendered = safe_render(base)
    if save_renders, do: save_render(base_rendered, "#{stem}.RFC2822.eml")

    Enum.flat_map(@parsers, fn {mod, parser_name} ->
      actual = safe_parse(mod, content)
      rendered = safe_render(actual)
      if save_renders, do: save_render(rendered, "#{stem}.#{parser_name}.eml")

      struct_diffs = compare_structs(base, actual)
      render_diffs = compare_rendered(base_rendered, rendered)

      diffs =
        if(struct_diffs == [], do: [], else: [{"struct", struct_diffs}]) ++
          if render_diffs == [], do: [], else: [{"render", render_diffs}]

      if diffs == [], do: [], else: [{parser_name, diffs}]
    end)
  end

  defp compare_structs({:error, a}, {:error, a}), do: []

  defp compare_structs({:error, base}, {:error, actual}),
    do: ["ground truth error: #{base}\n      actual error:       #{actual}"]

  defp compare_structs({:error, base}, %Mail.Message{}),
    do: ["ground truth raised: #{base}, parser succeeded"]

  defp compare_structs(%Mail.Message{}, {:error, e}),
    do: ["parser raised: #{e}"]

  defp compare_structs(%Mail.Message{} = expected, %Mail.Message{} = actual),
    do: diff_messages(expected, actual, [])

  defp compare_rendered({:error, a}, {:error, a}), do: []

  defp compare_rendered({:error, base}, {:error, actual}),
    do: ["ground truth render error: #{base}\n      actual render error:       #{actual}"]

  defp compare_rendered({:error, base}, _),
    do: ["ground truth render raised: #{base}"]

  defp compare_rendered(_, {:error, e}),
    do: ["render raised: #{e}"]

  defp compare_rendered(expected, actual) when expected == actual, do: []

  defp compare_rendered(expected, actual) do
    expected_lines = String.split(expected, ~r/\r?\n/)
    actual_lines = String.split(actual, ~r/\r?\n/)

    expected_lines
    |> Enum.zip(actual_lines)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {{expected, actual}, line_no} ->
      if expected == actual,
        do: [],
        else: [
          "line #{line_no}:\n\texpected: #{inspect(expected)}\n\tactual:   #{inspect(actual)}"
        ]
    end)
    |> case do
      [] when length(expected_lines) != length(actual_lines) ->
        ["line count: expected #{length(expected_lines)}, got #{length(actual_lines)}"]

      diffs ->
        diffs
    end
  end

  defp diff_messages(%Mail.Message{} = exp, %Mail.Message{} = act, path) do
    []
    |> diff_headers(exp.headers, act.headers, path)
    |> diff_field("body", exp.body, act.body, path)
    |> diff_field("multipart", exp.multipart, act.multipart, path)
    |> diff_parts(exp.parts, act.parts, path)
  end

  defp diff_headers(acc, exp_headers, act_headers, path) do
    all_keys =
      MapSet.union(MapSet.new(Map.keys(exp_headers)), MapSet.new(Map.keys(act_headers)))

    Enum.reduce(all_keys, acc, fn key, a ->
      diff_field(a, "headers[#{inspect(key)}]", exp_headers[key], act_headers[key], path)
    end)
  end

  defp diff_field(acc, field, exp, act, path) do
    exp = normalize(exp)
    act = normalize(act)

    if exp == act do
      acc
    else
      prefix = path_prefix(path)
      log = "#{prefix}#{field}:\n\texpected: #{inspect(exp)}\n\tactual:   #{inspect(act)}"
      [log | acc]
    end
  end

  defp normalize(s) when is_binary(s), do: String.replace(s, "\r\n", "\n") |> String.trim()
  defp normalize(other), do: other

  defp diff_parts(acc, nil, nil, _), do: acc
  defp diff_parts(acc, [], [], _), do: acc

  defp diff_parts(acc, exp_parts, act_parts, path) do
    exp_parts = exp_parts || []
    act_parts = act_parts || []

    if length(exp_parts) != length(act_parts) do
      prefix = path_prefix(path)
      ["#{prefix}parts: expected #{length(exp_parts)}, got #{length(act_parts)}" | acc]
    else
      exp_parts
      |> Enum.zip(act_parts)
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {{exp, act}, idx}, a ->
        diff_messages(exp, act, path ++ ["parts[#{idx}]"]) ++ a
      end)
    end
  end

  defp path_prefix([]), do: ""
  defp path_prefix(path), do: Enum.join(path, ".") <> "."

  defp print_failures(failures) do
    Enum.each(failures, fn {path, diffs} ->
      IO.puts(String.duplicate("-", 80))
      IO.puts("FAIL: #{path}")

      Enum.each(diffs, fn {parser_name, sections} ->
        IO.puts("  [#{parser_name}]")

        Enum.each(sections, fn {section, lines} ->
          IO.puts("    (#{section})")
          Enum.each(lines, fn line -> IO.puts("      #{line}") end)
        end)
      end)

      IO.puts("")
    end)
  end

  defp safe_parse(mod, content) do
    mod.parse(content)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp safe_render({:error, _} = err), do: err

  defp safe_render(%Mail.Message{} = message) do
    Mail.Renderers.RFC2822.render(message) |> String.trim()
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp save_render({:error, reason}, filename),
    do: File.write!(Path.join(@tmp_dir, filename), "ERROR: #{reason}\n")

  defp save_render(rendered, filename), do: File.write!(Path.join(@tmp_dir, filename), rendered)

  defp read_eml!(path) do
    File.read!(path)
    |> String.replace("\r\n", "\n")
    |> String.replace("\n", "\r\n")
    |> String.trim()
  end

  defp walk_files_in_paths(paths) do
    Enum.flat_map(paths, fn path ->
      if File.dir?(path) do
        path
        |> File.ls!()
        |> Enum.sort()
        |> Enum.map(&Path.join(path, &1))
        |> walk_files_in_paths()
      else
        [path]
      end
    end)
  end
end

ParserComparison.run(System.argv())
