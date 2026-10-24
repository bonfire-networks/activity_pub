# Compares the two RFC 8785 (JCS) libraries we could use for FEP-8b32 proofs: `jcs` (already in our tree through `rdf`) and `rfc8785`. Adapted from https://github.com/yaglo/rfc8785/blob/main/bench/run.exs
#
# It checks agreement first, since a signature made over different bytes than the signer's is worse than a slow one, and benchmarks second.
#
#     cd forks/activity_pub && mise exec -- elixir bench/jcs_compare.exs
#
# Needs network the first time (Mix.install fetches hex packages into a cache outside the project, so no lockfile or deps/ changes). `rfc8785` requires OTP 29 and Elixir 1.20.2+.

Mix.install([
  {:jcs, "~> 0.2"},
  {:rfc8785, "~> 1.0"},
  {:jason, "~> 1.4"},
  {:benchee, "~> 1.3"}
])

defmodule JcsCompare do
  def run_lib(:jcs, term), do: safely(fn -> Jcs.encode(term) end)
  def run_lib(:rfc8785, term), do: safely(fn -> RFC8785.encode!(term) end)

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, Exception.message(e) |> String.slice(0, 90)}
  end

  # a double from its IEEE-754 bit pattern, as RFC 8785 appendix B lists them
  def double(hex) do
    <<f::float-64>> = <<hex::64>>
    f
  end

  def show({:ok, bin}), do: inspect(bin, limit: 90, printable_limit: 90)
  def show({:error, msg}), do: "ERROR: " <> msg

  def compare(label, term, expected \\ :none) do
    a = run_lib(:jcs, term)
    b = run_lib(:rfc8785, term)

    verdict =
      cond do
        a == b and (expected == :none or a == {:ok, expected}) -> "same"
        a == b -> "SAME BUT NOT THE EXPECTED"
        true -> "DIFFERENT"
      end

    IO.puts("#{String.pad_trailing(verdict, 26)} #{label}")

    if verdict != "same" do
      IO.puts("    jcs:     #{show(a)}")
      IO.puts("    rfc8785: #{show(b)}")
      if expected != :none, do: IO.puts("    expected: #{inspect(expected)}")
    end

    verdict == "same"
  end
end

IO.puts("== RFC 8785 appendix B numbers ==")

numbers = [
  {0x0000000000000000, "0"},
  {0x8000000000000000, "0"},
  {0x0000000000000001, "5e-324"},
  {0x8000000000000001, "-5e-324"},
  {0x7FEFFFFFFFFFFFFF, "1.7976931348623157e+308"},
  {0xFFEFFFFFFFFFFFFF, "-1.7976931348623157e+308"},
  {0x4340000000000000, "9007199254740992"},
  {0xC340000000000000, "-9007199254740992"},
  {0x4430000000000000, "295147905179352830000"},
  {0x44B52D02C7E14AF5, "9.999999999999997e+22"},
  {0x44B52D02C7E14AF6, "1e+23"},
  {0x44B52D02C7E14AF7, "1.0000000000000001e+23"},
  {0x444B1AE4D6E2EF4E, "999999999999999700000"},
  {0x444B1AE4D6E2EF4F, "999999999999999900000"},
  {0x444B1AE4D6E2EF50, "1e+21"},
  {0x3EB0C6F7A0B5ED8C, "9.999999999999997e-7"},
  {0x3EB0C6F7A0B5ED8D, "0.000001"},
  {0x41B3DE4355555553, "333333333.3333332"},
  {0x41B3DE4355555554, "333333333.33333325"},
  {0x41B3DE4355555555, "333333333.3333333"},
  {0x41B3DE4355555556, "333333333.3333334"},
  {0x41B3DE4355555557, "333333333.33333343"},
  {0xBECBF647612F3696, "-0.0000033333333333333333"},
  {0x43143FF3C1CB0959, "1424953923781206.2"}
]

number_results =
  for {hex, expected} <- numbers do
    JcsCompare.compare("0x#{Integer.to_string(hex, 16)} -> #{expected}", %{"n" => JcsCompare.double(hex)}, ~s({"n":#{expected}}))
  end

IO.puts("\n== Key order (RFC 8785 section 3.2.3): UTF-16 code units, not code points ==")

sorting_input = %{
  "€" => "Euro Sign",
  "\r" => "Carriage Return",
  "דּ" => "Hebrew Letter Dalet With Dagesh",
  "1" => "One",
  "\u{1F600}" => "Emoji: Grinning Face",
  "\u0080" => "Control",
  "ö" => "Latin Small Letter O With Diaeresis"
}

sorting_expected =
  "{" <>
    Enum.join(
      [
        ~s("\\r":"Carriage Return"),
        ~s("1":"One"),
        ~s("\u0080":"Control"),
        ~s("ö":"Latin Small Letter O With Diaeresis"),
        ~s("€":"Euro Sign"),
        ~s("\u{1F600}":"Emoji: Grinning Face"),
        ~s("דּ":"Hebrew Letter Dalet With Dagesh")
      ],
      ","
    ) <> "}"

sorting_result = JcsCompare.compare("RFC 8785 sorting example", sorting_input, sorting_expected)

IO.puts("\n== Strings, scalars and structure ==")

other_results =
  [
    JcsCompare.compare("control characters", %{"s" => "\u0000\u0001\b\t\n\f\r\u001f\u007f"}, ~s({"s":"\\u0000\\u0001\\b\\t\\n\\f\\r\\u001f\u007f"})),
    JcsCompare.compare("quote, backslash, solidus", %{"s" => ~s(a"b\\c/d</script>)}, ~s({"s":"a\\"b\\\\c/d</script>"})),
    JcsCompare.compare("line and paragraph separators stay literal", %{"s" => <<0xE2, 0x80, 0xA8, 0xE2, 0x80, 0xA9>>}, "{\"s\":\"" <> <<0xE2, 0x80, 0xA8, 0xE2, 0x80, 0xA9>> <> "\"}"),
    JcsCompare.compare("astral plane", %{"s" => "a🎌b"}, ~s({"s":"a🎌b"})),
    JcsCompare.compare("literals", %{"t" => true, "f" => false, "n" => nil}, ~s({"f":false,"n":null,"t":true})),
    JcsCompare.compare("empty containers", %{"m" => %{}, "l" => []}, ~s({"l":[],"m":{}})),
    JcsCompare.compare("integers", [0, -1, 1, 9_007_199_254_740_991], "[0,-1,1,9007199254740991]"),
    JcsCompare.compare("float with integer value", %{"n" => 100.0}, ~s({"n":100})),
    JcsCompare.compare("negative zero", %{"n" => -0.0}, ~s({"n":0})),
    JcsCompare.compare("atom key", %{a: 1}),
    JcsCompare.compare("nested lists keep order", %{"l" => [3, [2, 1], %{"b" => 1, "a" => 2}]}, ~s({"l":[3,[2,1],{"a":2,"b":1}]}))
  ]

IO.puts("\n== Known divergence: an integer past 2^53, which IEEE-754 (so JavaScript signers) cannot hold ==")
# `jcs` emits the digits as given, so it would hash 9007199254740993 where a JavaScript signer hashed 9007199254740992 and the proof would fail without saying why. `rfc8785` refuses the input. Informational, not counted in the agreement verdict.
JcsCompare.compare("integer 2^53 + 1", %{"n" => 9_007_199_254_740_993})

IO.puts("\n== Real ActivityPub documents (test/fixtures/*.json, decoded with Jason) ==")

fixtures =
  Path.wildcard(Path.join(__DIR__, "../test/fixtures/**/*.json"))
  |> Enum.flat_map(fn path ->
    case Jason.decode(File.read!(path)) do
      {:ok, doc} -> [{Path.basename(path), doc}]
      _ -> []
    end
  end)

fixture_outcomes =
  for {name, doc} <- fixtures do
    a = JcsCompare.run_lib(:jcs, doc)
    b = JcsCompare.run_lib(:rfc8785, doc)
    {name, a, b}
  end

agree = Enum.count(fixture_outcomes, fn {_, a, b} -> a == b end)
IO.puts("#{length(fixtures)} documents, #{agree} identical output")

for {name, a, b} <- fixture_outcomes, a != b do
  IO.puts("  DIFFERENT #{name}")
  IO.puts("    jcs:     #{JcsCompare.show(a)}")
  IO.puts("    rfc8785: #{JcsCompare.show(b)}")
end

IO.puts("\n== rfc8785 JSON-text path: canonicalize/1 (only rfc8785 has one; with jcs we would Jason.decode first) ==")

defmodule JsonText do
  # `expected` is {:ok, canonical} or {:error, reason}, matched on the error's `reason` atom
  def check(label, text, expected) do
    got =
      case RFC8785.canonicalize(text) do
        {:ok, bin} -> {:ok, bin}
        {:error, %{reason: reason}} -> {:error, reason}
      end

    ok? = got == expected
    IO.puts("#{String.pad_trailing(if(ok?, do: "as expected", else: "UNEXPECTED"), 26)} #{label}")
    if not ok?, do: IO.puts("    got: #{inspect(got)}\n    expected: #{inspect(expected)}")
    ok?
  end

  # no expectation, just report what happens
  def observe(label, text) do
    got =
      case RFC8785.canonicalize(text) do
        {:ok, bin} -> "ok #{inspect(bin, limit: 60, printable_limit: 60)}"
        {:error, %{reason: reason}} -> "error #{inspect(reason)}"
      end

    IO.puts("#{String.pad_trailing("observed", 26)} #{label}: #{got}")
  end
end

text_results =
  [
    JsonText.check("whitespace and order are normalised", ~s(  {"b" : [1, 2.50], "a":\n"x"}  ), {:ok, ~s({"a":"x","b":[1,2.5]})}),
    JsonText.check("number spellings", "[1E30, 1.0, 4.50, 1e-7, 0.1e1, 1e21, 123456789012345678]", {:error, :integer_unrepresentable}),
    JsonText.check("number spellings, in range", "[1E30, 1.0, 4.50, 1e-7, 0.1e1, 1e21]", {:ok, "[1e+30,1,4.5,1e-7,1,1e+21]"}),
    JsonText.check("escapes are decoded and re-minimised", ~S("A\/\u007fé€"), {:ok, "\"A/\u007fé€\""}),
    JsonText.check("surrogate pair escape becomes the character", "\"\\ud83d\\ude00\"", {:ok, "\"\u{1F600}\""}),
    JsonText.check("duplicate names are rejected", ~s({"a":1,"a":2}), {:error, :duplicate_name}),
    JsonText.check("duplicate names after unescaping are rejected", ~s({"a":1,"\\u0061":2}), {:error, :duplicate_name}),
    JsonText.check("nested duplicate names are rejected", ~s({"o":{"k":1,"k":1}}), {:error, :duplicate_name}),
    JsonText.check("noncharacter escape U+FFFF", "\"a\\uFFFFb\"", {:error, :noncharacter}),
    JsonText.check("noncharacter escape U+FDD0", "\"\\uFDD0\"", {:error, :noncharacter}),
    JsonText.check("noncharacter escape U+FFFE in a name", "{\"\\uFFFE\":1}", {:error, :noncharacter}),
    JsonText.check("negative zero: -0", "-0", {:error, :negative_zero}),
    JsonText.check("negative zero: -0.0", "-0.0", {:error, :negative_zero}),
    JsonText.check("negative zero: -0e0", "[-0e0]", {:error, :negative_zero}),
    JsonText.check("-0 inside a string is left alone", ~S("-0"), {:ok, ~S("-0")}),
    JsonText.check("plain zero", "[0, 0.0]", {:ok, "[0,0]"}),
    JsonText.check("trailing data", "{} x", {:error, :trailing_data}),
    JsonText.check("trailing whitespace is fine", "{}  \n\t", {:ok, "{}"}),
    JsonText.check("truncated", "{", {:error, :unexpected_end}),
    JsonText.check("empty input", "", {:error, :unexpected_end}),
    JsonText.check("number past the double range", "1e400", {:error, :number_out_of_range}),
    JsonText.check("integer past 2^53", "9007199254740993", {:error, :integer_unrepresentable}),
    JsonText.check("integer of exactly 2^53", "9007199254740992", {:ok, "9007199254740992"}),
    JsonText.check("22-digit integer is refused without building a bignum", String.duplicate("9", 22), {:error, :integer_unrepresentable}),
    # OTP reports a high surrogate with no room for a low one as a truncated input, which the library's own comments say
    JsonText.check("unpaired high surrogate at the end", ~S("\ud800"), {:error, :unexpected_end}),
    JsonText.check("unpaired high surrogate followed by text", ~S("\ud800abcdef"), {:error, :syntax}),
    JsonText.check("null stays null", ~S({"a":null}), {:ok, ~S({"a":null})}),
    JsonText.check("single quotes are not JSON", "{'a':1}", {:error, :syntax}),
    JsonText.check("trailing comma is not JSON", "[1,]", {:error, :syntax}),
    JsonText.check("NaN is not JSON", "NaN", {:error, :syntax})
  ]

# The same Jason-based route we would take with `jcs`, to show what a plain decoder lets through
IO.puts("\nWhat the Jason + Jcs route does with the inputs rfc8785 refuses:")

for {label, text} <- [
      {"duplicate names", ~s({"a":1,"a":2})},
      {"noncharacter U+FFFF", "\"a\\uFFFFb\""},
      {"integer 2^53 + 1", "9007199254740993"}
    ] do
  result = text |> Jason.decode!() |> Jcs.encode()
  IO.puts("  #{String.pad_trailing(label, 22)} -> #{inspect(result)}")
end

IO.puts("\nObserved, no expectation (edge cases the RFC leaves to the parser):")
JsonText.observe("byte order mark first", <<0xEF, 0xBB, 0xBF>> <> ~s({"a":1}))
JsonText.observe("invalid UTF-8 in a string", <<?", 0xFF, ?">>)
JsonText.observe("lone low surrogate escape", ~S("\udc00"))
JsonText.observe("literal U+FFFF byte sequence", <<?", 0xEF, 0xBF, 0xBF, ?">>)
JsonText.observe("control character raw inside string", <<?", 0x01, ?">>)

# No depth limit is documented, so see what a hostile document does to the process. Run in a throwaway process with a heap cap, so a runaway kills only it.
for depth <- [1_000, 100_000, 1_000_000] do
  text = String.duplicate("[", depth) <> String.duplicate("]", depth)
  parent = self()

  {pid, ref} =
    spawn_monitor(fn ->
      Process.flag(:max_heap_size, %{size: 200_000_000, kill: true, error_logger: false})
      {us, result} = :timer.tc(fn -> RFC8785.canonicalize(text) end)
      send(parent, {:done, elem(result, 0), us})
    end)

  outcome =
    receive do
      {:done, status, us} -> "#{status} in #{div(us, 1000)} ms"
      {:DOWN, ^ref, _, _, reason} -> "process died: #{inspect(reason)}"
    after
      20_000 -> Process.exit(pid, :kill) && "timed out after 20 s"
    end

  IO.puts("#{String.pad_trailing("observed", 26)} nesting depth #{depth}: #{outcome}")
end

# Consistency: the text path must agree with the term path on every real document
IO.puts("\nText path against term path on the fixtures:")

text_vs_term =
  for path <- Path.wildcard(Path.join(__DIR__, "../test/fixtures/**/*.json")),
      text = File.read!(path),
      {:ok, doc} <- [Jason.decode(text)] do
    {Path.basename(path), RFC8785.canonicalize(text), RFC8785.encode(doc)}
  end

# A document with a repeated member name is where the two routes SHOULD differ: Jason keeps the last value silently, the text path refuses (I-JSON). Listed apart so it does not count as a failure.
duplicate_name? = fn
  {:error, %{reason: :duplicate_name}} -> true
  _ -> false
end

{refused_duplicates, comparable} = Enum.split_with(text_vs_term, fn {_, a, _} -> duplicate_name?.(a) end)
text_agree = Enum.count(comparable, fn {_, a, b} -> a == b end)
IO.puts("#{length(comparable)} documents, #{text_agree} identical")

for {name, _, _} <- refused_duplicates do
  IO.puts("  refused for a repeated member name (Jason keeps the last silently): #{name}")
end

for {name, a, b} <- comparable, a != b do
  IO.puts("  DIFFERENT #{name}")
  IO.puts("    canonicalize(text): #{inspect(a, limit: 5, printable_limit: 120)}")
  IO.puts("    encode(Jason term): #{inspect(b, limit: 5, printable_limit: 120)}")
end

# The proof workflow from FEP-8b32: remove `proof`, then hash. decode!/1 keeps null as nil, so the terms re-encode correctly
doc_text = ~s({"type":"Note","content":null,"proof":{"proofValue":"zabc"},"to":["https://www.w3.org/ns/activitystreams#Public"]})
without_proof_text = ~s({"type":"Note","content":null,"to":["https://www.w3.org/ns/activitystreams#Public"]})

proof_flow_ok? =
  doc_text |> RFC8785.decode!() |> Map.delete("proof") |> RFC8785.encode!() ==
    RFC8785.canonicalize!(without_proof_text)

IO.puts("#{String.pad_trailing(if(proof_flow_ok?, do: "as expected", else: "UNEXPECTED"), 26)} decode!, drop proof, encode! equals canonicalizing the text without it")

IO.puts("\n== Data Integrity test vectors: eddsa-jcs-2022 end to end, once per canonicalizer ==")

# base58btc (multibase 'z'), as FEP-8b32 and vc-di-eddsa use for keys and signatures. A throwaway version of what Phase 1 will write in `ActivityPub.Safety.Multibase`.
defmodule B58 do
  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  def decode("z" <> s) do
    zeros = count_leading(s, ?1)

    n =
      s
      |> String.to_charlist()
      |> Enum.reduce(0, fn c, acc -> acc * 58 + Enum.find_index(@alphabet, &(&1 == c)) end)

    :binary.copy(<<0>>, zeros) <> if(n == 0, do: <<>>, else: :binary.encode_unsigned(n))
  end

  def encode(bin) do
    zeros = count_leading(bin, 0)
    "z" <> String.duplicate("1", zeros) <> (bin |> :binary.decode_unsigned() |> digits([]) |> List.to_string())
  end

  defp digits(0, acc), do: acc
  defp digits(n, acc), do: digits(div(n, 58), [Enum.at(@alphabet, rem(n, 58)) | acc])

  defp count_leading(<<byte, rest::binary>>, byte), do: 1 + count_leading(rest, byte)
  defp count_leading(<<>>, _byte), do: 0
  defp count_leading(<<_, _::binary>>, _byte), do: 0
end

defmodule DataIntegrity do
  def hash(encode, proof_config, doc),
    do: :crypto.hash(:sha256, encode.(proof_config)) <> :crypto.hash(:sha256, encode.(doc))

  def hex(bin), do: Base.encode16(bin, case: :lower)
end

# The vectors live in test/fixtures/integrity_proofs/, so the Phase 1 tests read the same files.
#   vector.json holds the keys and what the spec lists; the documents beside it are added under fixed keys
#   (the same reading as `ActivityPub.Test.IntegrityProofFixtures.vector/1`)
load_vector = fn name ->
  dir = Path.join([__DIR__, "..", "test", "fixtures", "integrity_proofs", name])
  read = fn file -> dir |> Path.join(file) |> File.read!() |> Jason.decode!() end

  documents = %{
    "unsigned.json" => "document",
    "credential.json" => "document",
    "signed.json" => "signedDocument",
    "actor.json" => "actor",
    "proof_options.json" => "proofOptions"
  }

  for {file, key} <- documents, File.exists?(Path.join(dir, file)), into: read.("vector.json") do
    {key, read.(file)}
  end
end

w3c = load_vector.("vc_di_eddsa_jcs_2022")
fep = load_vector.("fep_8b32")

# Ed25519 keypair from the vc-di-eddsa example 29, which the FEP-8b32 feature file reuses.
# secretKeyMultibase is 0x8026 || seed, publicKeyMultibase is 0xed01 || key.
<<0x80, 0x26, seed::binary-size(32)>> = B58.decode(w3c["secretKeyMultibase"])
<<0xED, 0x01, published_key::binary-size(32)>> = B58.decode(w3c["publicKeyMultibase"])
{derived_key, _} = :crypto.generate_key(:eddsa, :ed25519, seed)

# the FEP file must name the same key, or its vector would check the wrong thing
same_key? = fep["secretKeyMultibase"] == w3c["secretKeyMultibase"] and fep["publicKeyMultibase"] == w3c["publicKeyMultibase"]
IO.puts("#{String.pad_trailing(if(same_key?, do: "as expected", else: "UNEXPECTED"), 26)} both vector files use the same key pair")

key_ok? = derived_key == published_key
IO.puts("#{String.pad_trailing(if(key_ok?, do: "as expected", else: "UNEXPECTED"), 26)} multibase key decoding: the published key is the one derived from the secret key")

round_trip_ok? = B58.encode(<<0, 0, 1, 2, 3>>) |> B58.decode() == <<0, 0, 1, 2, 3>>
IO.puts("#{String.pad_trailing(if(round_trip_ok?, do: "as expected", else: "UNEXPECTED"), 26)} base58btc round trip with leading zero bytes")

# The FEP vector's proof configuration is the proof it published, minus its proofValue
fep_proof_config = Map.delete(fep["signedDocument"]["proof"], "proofValue")

# the same config as a signer who leaves the proof's own @context out, with ours then copied from the document, as the plan's section 1 does
fep_proof_config_without_context = Map.delete(fep_proof_config, "@context")

vectors = [
  {"vc-di-eddsa B.3 (W3C credential, did:key)", w3c["document"], w3c["proofOptions"],
   %{
     doc_hash: w3c["expected"]["documentHash"],
     proof_hash: w3c["expected"]["proofOptionsHash"],
     combined: w3c["expected"]["combinedHash"],
     signature_hex: w3c["expected"]["signatureHex"],
     proof_value: w3c["expected"]["proofValue"]
   }},
  {"FEP-8b32 feature (ActivityPub Create, https key)", fep["document"], fep_proof_config,
   %{
     canonical_doc: fep["expected"]["canonicalDocument"],
     canonical_proof_config: fep["expected"]["canonicalProofConfig"],
     combined: fep["expected"]["combinedHash"],
     proof_value: fep["expected"]["proofValue"]
   }}
]

# the document the FEP file shows signed must be the unsigned one plus that proof, or the two copies of it have drifted
signed_matches? = Map.delete(fep["signedDocument"], "proof") == fep["document"]
IO.puts("#{String.pad_trailing(if(signed_matches?, do: "as expected", else: "UNEXPECTED"), 26)} FEP vector: signedDocument is document plus proof")

vector_results =
  for {canonicalizer, encode} <- [{"jcs", &Jcs.encode/1}, {"rfc8785", &RFC8785.encode!/1}],
      {vector_name, doc, proof_config, want} <- vectors,
      reduce: [] do
    results ->
      label = "#{canonicalizer} / #{vector_name}"
      hash = DataIntegrity.hash(encode, proof_config, doc)
      signature = :crypto.sign(:eddsa, :none, hash, [seed, :ed25519])

      checks =
        [
          {"combined hash", DataIntegrity.hex(hash), want.combined},
          {"proofValue", B58.encode(signature), want.proof_value}
        ] ++
          if(want[:doc_hash], do: [{"document hash", DataIntegrity.hex(:crypto.hash(:sha256, encode.(doc))), want.doc_hash}], else: []) ++
          if(want[:proof_hash], do: [{"proof config hash", DataIntegrity.hex(:crypto.hash(:sha256, encode.(proof_config))), want.proof_hash}], else: []) ++
          if(want[:signature_hex], do: [{"signature", DataIntegrity.hex(signature), want.signature_hex}], else: []) ++
          if(want[:canonical_doc], do: [{"canonical document", encode.(doc), want.canonical_doc}], else: []) ++
          if(want[:canonical_proof_config], do: [{"canonical proof config", encode.(proof_config), want.canonical_proof_config}], else: [])

      # verification: decode the proofValue, check it against the published key, then a tampered document must fail
      verifies? = :crypto.verify(:eddsa, :none, hash, B58.decode(want.proof_value), [published_key, :ed25519])
      tampered_hash = DataIntegrity.hash(encode, proof_config, Map.put(doc, "id", "https://evil.example/x"))
      tamper_rejected? = not :crypto.verify(:eddsa, :none, tampered_hash, B58.decode(want.proof_value), [published_key, :ed25519])

      checks = checks ++ [{"verifies against the published key", verifies?, true}, {"tampered document is rejected", tamper_rejected?, true}]
      failed = for {what, got, expected} <- checks, got != expected, do: {what, got, expected}

      IO.puts("#{String.pad_trailing(if(failed == [], do: "as expected", else: "UNEXPECTED"), 26)} #{label} (#{length(checks)} checks)")

      for {what, got, expected} <- failed do
        IO.puts("    #{what}:\n      got      #{inspect(got)}\n      expected #{inspect(expected)}")
      end

      [failed == [] | results]
  end

# the proof's own @context left out: copying the document's must give the vector's hash
no_context_hash =
  DataIntegrity.hash(
    &RFC8785.encode!/1,
    Map.put(fep_proof_config_without_context, "@context", fep["document"]["@context"]),
    fep["document"]
  )

no_context_ok? = DataIntegrity.hex(no_context_hash) == fep["expected"]["combinedHash"]

IO.puts("#{String.pad_trailing(if(no_context_ok?, do: "as expected", else: "UNEXPECTED"), 26)} proof @context omitted, taken from the document: same hash as the vector")

vectors_ok? = Enum.all?(vector_results) and key_ok? and round_trip_ok? and no_context_ok? and same_key? and signed_matches?

all_ok? =
  Enum.all?(number_results ++ [sorting_result] ++ other_results ++ text_results) and vectors_ok? and
    agree == length(fixtures) and text_agree == length(comparable) and proof_flow_ok?

IO.puts("\n== Agreement: #{if all_ok?, do: "all cases the same", else: "SEE DIFFERENCES ABOVE"} ==\n")

# Benchmark. What we do per proof is canonicalise twice and SHA-256 both, so that is measured too.
small = %{"a" => 1, "b" => [1.5, "x", nil], "c" => %{"d" => true}}
wide = Map.new(1..200, fn i -> {"key_#{i}", i * 1.5} end)
deep = Enum.reduce(1..50, "leaf", fn i, acc -> %{"level_#{i}" => [acc, i, i * 0.5]} end)

strings = %{
  "ascii" => String.duplicate("hello world ", 100),
  "escapes" => String.duplicate("line\n\ttab \"quote\" ", 50),
  "unicode" => String.duplicate("日本語テキスト🎌", 50)
}

inputs =
  %{
    "small map" => small,
    "wide map (200 keys)" => wide,
    "deeply nested" => deep,
    "string-heavy" => strings
  }
  |> then(fn inputs ->
    case Enum.max_by(fixtures, fn {_, doc} -> byte_size(Jason.encode!(doc)) end, fn -> nil end) do
      {name, doc} -> Map.put(inputs, "largest fixture (#{name})", doc)
      nil -> inputs
    end
  end)

Benchee.run(
  %{
    "Jcs.encode" => fn term -> Jcs.encode(term) end,
    "RFC8785.encode!" => fn term -> RFC8785.encode!(term) end,
    "Jcs.encode + sha256" => fn term -> :crypto.hash(:sha256, Jcs.encode(term)) end,
    "RFC8785.encode_to_iodata! + sha256" => fn term -> :crypto.hash(:sha256, RFC8785.encode_to_iodata!(term)) end
  },
  inputs: inputs,
  time: 3,
  memory_time: 1
)
