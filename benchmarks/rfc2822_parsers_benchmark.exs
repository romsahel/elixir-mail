# Benchmark comparing RFC2822 parsers
alias Mail.Parsers.RFC2822Binary
alias Mail.Parsers.{RFC2822, RFC2822Stream}

eml_files = %{
  "medium" => "eml/fat_table.eml",
  "large" => "eml/fattest_eml.eml"
}

skip_handler = fn message, opts ->
  {:skip, %{message | body: "Custom body for part #{opts[:part_index]}"}}
end

# Benchee's memory_time measures CUMULATIVE bytes allocated during one run
# not peak live memory. For the stream parser, this includes all the
# temporary line binaries created by File.stream! that are immediately GC'd.
# This inflates the stream parser's figure and makes it look worse than it
IO.puts("=== CPU throughput ===")
IO.puts("NOTE: 'Memory usage' below = cumulative allocations (includes immediately")
IO.puts("GC'd temporaries). It is NOT peak live memory. See section above for that.\n")

Benchee.run(
  %{
    "RFC2822 (legacy)" => &RFC2822.parse(File.read!(&1)),
    "RFC2822Binary" => &RFC2822Binary.parse(File.read!(&1), parts_handler_fn: skip_handler),
    "RFC2822Stream" => &RFC2822Stream.parse(File.stream!(&1), parts_handler_fn: skip_handler)
  },
  inputs: eml_files,
  time: 5,
  memory_time: 2,
  formatters: [Benchee.Formatters.Console]
)
