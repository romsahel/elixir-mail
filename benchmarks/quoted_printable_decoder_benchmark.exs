# benchmarks/quoted_printable_decoder_benchmark.exs
# mix run benchmarks/quoted_printable_decoder_benchmark.exs

alias Mail.Encoders.QuotedPrintable

# Dense QP: every char encoded (e.g. all non-ASCII)
# 60_000 bytes, 20_000 encoded chars
dense = String.duplicate("=C3=A9", 10_000)

# Worst case for the binary accumulator: 30_000 single-byte =XX sequences.
# Each match triggers `acc <> <<byte>>`, copying the entire accumulator.
# Total bytes copied grows as O(N²): ~450 MB of copy work for 90 KB of input.
worst_case = String.duplicate("=FF", 30_000)

# Sparse QP: mostly plain ASCII with occasional encoded chars
sparse =
  String.duplicate("Hello, world! This is a fairly normal sentence. ", 200) <>
    String.duplicate("=C3=A9", 100)

# Mixed: realistic email body
mixed = String.duplicate("Subject line text =3D encoded =0D=0A more text ", 500)

Benchee.run(
  %{"QuotedPrintable.decode" => fn input -> QuotedPrintable.decode(input) end},
  inputs: %{"dense" => dense, "sparse" => sparse, "mixed" => mixed, "worst_case" => worst_case},
  time: 3,
  memory_time: 3,
  formatters: [Benchee.Formatters.Console]
)
