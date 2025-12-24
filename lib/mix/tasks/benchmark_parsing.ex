defmodule Mix.Tasks.BenchmarkParsing do
  @moduledoc """
  Benchmarks email parsing performance and memory usage.

  ## Usage

      mix benchmark_parsing

  This task will:
  1. Find all .eml files in the eml/ directory
  2. Benchmark both the original and streaming parsers
  3. Report memory usage for each parser

  Place your .eml test files in the `eml/` directory before running this task.
  """

  use Mix.Task

  @shortdoc "Benchmarks email parsing performance and memory usage"

  @impl Mix.Task
  def run(_args) do
    eml_files = find_eml_files()

    if Enum.empty?(eml_files) do
      Mix.shell().error("""
      No .eml files found in the eml/ directory.
      Please add some .eml test files to benchmark.
      """)

      System.halt(1)
    end

    Mix.shell().info("Found #{length(eml_files)} .eml file(s) to process")
    Mix.shell().info("")

    # # Benchmark each parser
    # Enum.each(eml_files, fn path ->
    #   Mix.shell().info("Processing: #{Path.basename(path)}")

    #   Benchee.run(
    #     %{
    #       "RFC2822 (original)" => fn ->
    #         content = File.read!(path)
    #         Mail.Parsers.RFC2822.parse(content)
    #       end,
    #       "RFC2822Stream" => fn ->
    #         Mail.Parsers.RFC2822Stream.parse(File.stream!(path),
    #           parts_handler_fn: fn message, _opts -> {:skip, message} end
    #         )
    #       end,
    #       "RFC2822GMime" => fn ->
    #         {:ok, message} = Mail.Parsers.GMime.parse_stream(path)
    #       end
    #     },
    #     time: 10,
    #     memory_time: 2
    #   )
    # end)

    # Benchee.run(
    #   %{
    #     "RFC2822 (original)" => fn ->
    #       Enum.each(eml_files, fn path ->
    #         content = File.read!(path)
    #         Mail.Parsers.RFC2822.parse(content)
    #       end)
    #     end,
    #     "RFC2822Stream (new)" => fn ->
    #       Enum.each(eml_files, fn path ->
    #         Mail.Parsers.RFC2822Stream.parse(File.stream!(path),
    #           parts_handler_fn: fn message, _opts -> {:skip, message} end
    #         )
    #       end)
    #     end
    #   },
    #   time: 10,
    #   memory_time: 2
    # )
  end

  defp find_eml_files do
    eml_dir = Path.join(File.cwd!(), "eml")

    if File.exists?(eml_dir) and File.dir?(eml_dir) do
      Path.join(eml_dir, "*.eml")
      |> Path.wildcard()
      |> Enum.sort()
    else
      []
    end
  end
end
