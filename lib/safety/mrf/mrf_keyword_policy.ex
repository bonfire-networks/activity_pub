# Copyright © 2026 Bonfire Contributors <https://bonfirenetworks.org/>
# Copyright © 2017-2025 Pleroma & Akkoma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.MRF.KeywordPolicy do
  alias ActivityPub.MRF
  alias ActivityPub.Config
  alias ActivityPub.Object
  import Untangle

  @moduledoc "Reject or Word-Replace messages with a keyword or regex"

  @behaviour MRF

  # @impl true
  # def config_description do
  #   %{
  #     key: :mrf_keyword,
  #     related_policy: "ActivityPub.MRF.KeywordPolicy",
  #     label: "MRF Keyword",
  #     description:
  #       "Reject or Word-Replace messages matching a keyword or [Regex](https://hexdocs.pm/elixir/Regex.html).",
  #     children: [
  #       %{
  #         key: :reject,
  #         type: {:list, :string},
  #         description: """
  #           A list of patterns which result in message being rejected.

  #           Each pattern can be a string or [Regex](https://hexdocs.pm/elixir/Regex.html) in the format of `~r/PATTERN/`.
  #         """,
  #         suggestions: ["foo", ~r/foo/iu]
  #       },
  #       %{
  #         key: :federated_timeline_removal,
  #         type: {:list, :string},
  #         description: """
  #           A list of patterns which result in message being removed from federated timelines (a.k.a unlisted).

  #           Each pattern can be a string or [Regex](https://hexdocs.pm/elixir/Regex.html) in the format of `~r/PATTERN/`.
  #         """,
  #         suggestions: ["foo", ~r/foo/iu]
  #       },
  #       %{
  #         key: :replace,
  #         type: {:list, :tuple},
  #         key_placeholder: "instance",
  #         value_placeholder: "reason",
  #         description: """
  #           **Pattern**: a string or [Regex](https://hexdocs.pm/elixir/Regex.html) in the format of `~r/PATTERN/`.

  #           **Replacement**: a string. Leaving the field empty is permitted.
  #         """
  #       }
  #     ]
  #   }
  # end

  defp string_matches?(string, _) when not is_binary(string) do
    false
  end

  # For string patterns: case-insensitive comparison
  defp string_matches?(string, pattern) when is_binary(pattern) do
    downcased_string = String.downcase(string)
    # TODO: optimise by downcasing the pattern when it is set in config
    downcased_pattern = String.downcase(pattern)

    cond do
      String.contains?(downcased_string, downcased_pattern) ->
        :exact

      confusables_enabled?() ->
        normalized_string =
          string
          |> normalize_for_matching()
          |> String.downcase()
          |> flood("normalised string '#{string}'")

        if normalized_string
           |> String.contains?(downcased_pattern) or
             normalized_string
             # reverse homoglyph just in case
             |> String.replace("rn", "m")
             |> String.contains?(downcased_pattern), do: :confusable, else: false

      true ->
        false
    end
  end

  # For regex patterns
  defp string_matches?(string, pattern) do
    # NOTE: users can add the i flag in the pattern (e.g., ~r/pattern/i)

    cond do
      String.match?(string, pattern) ->
        :exact

      confusables_enabled?() ->
        normalized_string =
          string
          |> normalize_for_matching()
          |> flood("normalised string '#{string}'")

        if normalized_string
           |> String.match?(pattern) or
             normalized_string
             # reverse homoglyph just in case
             |> String.replace("rn", "m")
             |> String.match?(pattern), do: :confusable, else: false

      true ->
        false
    end
  end

  # Multi-step normalization to catch various Unicode evasion techniques
  defp normalize_for_matching(string) do
    string
    |> strip_zero_width_chars()
    |> nfkc_normalize()
    |> ExConfusables.skeleton()
    |> strip_diacritics()
  end

  # Remove zero-width characters used to break up words
  defp strip_zero_width_chars(string) do
    # U+200B Zero Width Space, U+200C Zero Width Non-Joiner,
    # U+200D Zero Width Joiner, U+FEFF Byte Order Mark/Zero Width No-Break Space
    String.replace(string, ~r/[\x{200B}\x{200C}\x{200D}\x{FEFF}]/u, "")
  end

  # NFKC normalization decomposes compatibility characters:
  # - Enclosed alphanumerics (Ⓐ → A)
  # - Full-width chars (Ａ → A)
  # - Ligatures (ﬁ → fi)
  # - Superscript/subscript (² → 2)
  defp nfkc_normalize(string) do
    :unicode.characters_to_nfkc_binary(string)
  end

  # Strip combining diacritical marks (accents, etc.) after NFKD decomposition
  defp strip_diacritics(string) do
    string
    |> :unicode.characters_to_nfkd_binary()
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
  end

  defp confusables_enabled? do
    Config.get([:mrf_keyword, :detect_confusables], true)
  end

  defp match_type_message(:exact), do: "[KeywordPolicy] Matches rejected keyword"

  defp match_type_message(:confusable),
    do: "[KeywordPolicy] Matches rejected keyword (confusable/homoglyph detected)"

  defp object_payload(%{} = object) do
    [object["content"], object["summary"], object["name"]]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp check_reject(%{"object" => %{} = object} = message) do
    with {:ok, _new_object} <-
           Object.apply_to_object_and_history(object, fn object ->
             payload = object_payload(object)

             case find_matching_pattern(payload, Config.get([:mrf_keyword, :reject])) do
               {:reject, match_type} ->
                 {:reject, match_type_message(match_type)}

               false ->
                 {:ok, message}
             end
           end) do
      {:ok, message}
    else
      e -> e
    end
  end

  defp find_matching_pattern(payload, patterns) do
    Enum.find_value(patterns, fn pattern ->
      case string_matches?(payload, pattern) do
        false -> false
        match_type -> {:reject, match_type}
      end
    end) || false
  end

  defp check_ftl_removal(%{"type" => "Create", "to" => to, "object" => %{} = object} = message) do
    check_keyword = fn object ->
      payload = object_payload(object)

      case find_matching_pattern(payload, Config.get([:mrf_keyword, :federated_timeline_removal])) do
        {:reject, match_type} ->
          {:should_delist, match_type}

        false ->
          {:ok, %{}}
      end
    end

    should_delist? = fn object ->
      with {:ok, _} <- Object.apply_to_object_and_history(object, check_keyword) do
        false
      else
        _ -> true
      end
    end

    if ActivityPub.Config.public_uri() in to and should_delist?.(object) do
      to = List.delete(to, ActivityPub.Config.public_uri())
      cc = [ActivityPub.Config.public_uri() | message["cc"] || []]

      message =
        message
        |> Map.put("to", to)
        |> Map.put("cc", cc)

      {:ok, message}
    else
      {:ok, message}
    end
  end

  defp check_ftl_removal(message) do
    {:ok, message}
  end

  defp check_replace(%{"object" => %{} = object} = message) do
    replace_kw = fn object ->
      ["content", "name", "summary"]
      |> Enum.filter(fn field -> Map.has_key?(object, field) && object[field] end)
      |> Enum.reduce(object, fn field, object ->
        data =
          Enum.reduce(
            Config.get([:mrf_keyword, :replace]),
            object[field],
            fn {pat, repl}, acc -> String.replace(acc, pat, repl) end
          )

        Map.put(object, field, data)
      end)
      |> (fn object -> {:ok, object} end).()
    end

    {:ok, object} = Object.apply_to_object_and_history(object, replace_kw)

    message = Map.put(message, "object", object)

    {:ok, message}
  end

  @impl true
  def filter(%{"type" => type, "object" => %{"content" => _content}} = message)
      when type in ["Create", "Update"] do
    with {:ok, message} <- check_reject(message),
         {:ok, message} <- check_ftl_removal(message),
         {:ok, message} <- check_replace(message) do
      {:ok, message}
    else
      {:reject, nil} -> {:reject, "[KeywordPolicy] "}
      {:reject, _} = e -> e
      _e -> {:reject, "[KeywordPolicy] "}
    end
  end

  @impl true
  def filter(message), do: {:ok, message}

  @impl true
  def describe do
    # This horror is needed to convert regex sigils to strings
    mrf_keyword =
      Config.get(:mrf_keyword, [])
      |> Enum.map(fn {key, value} ->
        {key,
         Enum.map(value, fn
           {pattern, replacement} ->
             %{
               "pattern" =>
                 if not is_binary(pattern) do
                   inspect(pattern)
                 else
                   pattern
                 end,
               "replacement" => replacement
             }

           pattern ->
             if not is_binary(pattern) do
               inspect(pattern)
             else
               pattern
             end
         end)}
      end)
      |> Enum.into(%{})

    {:ok, %{mrf_keyword: mrf_keyword}}
  end
end
