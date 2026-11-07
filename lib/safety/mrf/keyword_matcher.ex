# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.MRF.KeywordMatcher do
  @moduledoc """
  Matches a list of keywords against the visible text of some content: HTML tags are left out and entities decoded, case doesn't matter.

  A keyword matches a whole word (or phrase): `spam` matches "Spam!" and "#spam" but not "spammer" or "antispam". A `*` at either end lets it run into a longer word on that side: `spam*` matches "spammer", `*spam` matches "antispam", `*spam*` matches anywhere. A word boundary is a character that is not a letter, a digit or `_`, so a keyword may start or end with punctuation (`#tag`, `wow!`).

  Look-alike characters and invisible ones are folded with `ExConfusables` before matching too, unless `confusables: false` is given. `Regex` keywords are matched as they are, against the text and its folded form.

  Compile a list once with `compile/1` and match many times with `match?/3`.
  """

  @boundary_before "(?<![\\p{L}\\p{N}_])"
  @boundary_after "(?![\\p{L}\\p{N}_])"

  # a struct rather than a map, so code that walks settings (eg. turning the instance's into config at boot) leaves it whole
  defstruct regex: nil, regexes: []

  @type t :: %__MODULE__{regex: Regex.t() | nil, regexes: [Regex.t()]}
  @type compiled :: t | nil

  @doc "Compiles a list of keywords (strings, or `Regex` structs), returning `nil` when there is nothing to match"
  @spec compile(list | nil) :: compiled
  def compile(keywords) do
    {regexes, strings} =
      keywords
      |> List.wrap()
      |> Enum.split_with(&is_struct(&1, Regex))

    sources =
      strings
      |> Enum.flat_map(&keyword_source/1)
      |> Enum.uniq()

    regex =
      if sources != [],
        do: Regex.compile!("(?:" <> Enum.join(sources, "|") <> ")", "iu")

    if regex || regexes != [], do: %__MODULE__{regex: regex, regexes: regexes}
  end

  # a keyword as a pattern: escaped, with a word boundary on each side that has no `*`
  defp keyword_source(keyword) when is_binary(keyword) do
    keyword = String.trim(keyword)
    starts_open? = String.starts_with?(keyword, "*")
    ends_open? = String.ends_with?(keyword, "*")

    case keyword |> String.trim("*") |> String.trim() do
      "" ->
        []

      word ->
        [
          if(starts_open?, do: "", else: @boundary_before) <>
            Regex.escape(word) <> if(ends_open?, do: "", else: @boundary_after)
        ]
    end
  end

  # numbers and atoms stored by older code are matched as the text they stand for
  defp keyword_source(keyword)
       when is_integer(keyword) or (is_atom(keyword) and not is_nil(keyword)),
       do: keyword |> to_string() |> String.replace_prefix("Elixir.", "") |> keyword_source()

  defp keyword_source(_), do: []

  @doc """
  Whether any of `fields` matches the compiled keywords. Each field is HTML, a `LazyHTML` document already parsed by the caller, or `nil`.

  Options: `confusables: false` to skip folding look-alike characters.
  """
  @spec match?(compiled, list, keyword) :: boolean
  def match?(compiled, fields, opts \\ [])

  def match?(nil, _fields, _opts), do: false

  def match?(%{} = compiled, fields, opts) do
    texts =
      fields
      |> List.wrap()
      |> Enum.map(&ActivityPub.Utils.text_only/1)
      |> Enum.reject(&(&1 == ""))

    texts != [] and
      (Enum.any?(texts, &text_matches?(compiled, &1)) or
         (opts[:confusables] != false and
            Enum.any?(texts, fn text ->
              Enum.any?(folded(text), &text_matches?(compiled, &1))
            end)))
  end

  defp text_matches?(%{regex: regex, regexes: regexes}, text) do
    (regex != nil and Regex.match?(regex, text)) or Enum.any?(regexes, &Regex.match?(&1, text))
  end

  # the text with look-alike and invisible characters folded, and with "rn" read as "m" (a look-alike made of two letters)
  defp folded(text) do
    normalized = ExConfusables.normalize(text) || text
    Enum.uniq([normalized, String.replace(normalized, "rn", "m")]) -- [text]
  end
end
