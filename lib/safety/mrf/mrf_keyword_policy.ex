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

  defp find_matching_pattern(string, patterns) when is_list(patterns) do
    # TODO: optimise by splitting patterns when set in config
    {string_patterns, regex_patterns} = Enum.split_with(patterns, &is_binary/1)

    check_string_patterns(string, string_patterns) ||
      check_regex_patterns(string, regex_patterns) ||
      false
  end

  defp find_matching_pattern(_string, _), do: false

  defp check_string_patterns(_string, []), do: nil

  defp check_string_patterns(string, string_patterns) do
    downcased_string = String.downcase(string)
    # TODO: optimise by downcasing patterns when set in config
    downcased_patterns = Enum.map(string_patterns, &String.downcase/1)

    cond do
      String.contains?(downcased_string, downcased_patterns) ->
        {:reject, :exact}

      confusables_enabled?() ->
        normalized = string |> normalize_for_matching() |> String.downcase()

        # Also check "rn" → "m" reverse homoglyph
        if String.contains?(normalized, downcased_patterns) or
             String.contains?(String.replace(normalized, "rn", "m"), downcased_patterns) do
          {:reject, :confusable}
        end

      true ->
        nil
    end
  end

  defp check_regex_patterns(_string, []), do: nil

  defp check_regex_patterns(string, regex_patterns) do
    # NOTE: we don't downcase here since regexes may have their own i flag
    cond do
      Enum.any?(regex_patterns, &String.match?(string, &1)) ->
        {:reject, :exact}

      confusables_enabled?() ->
        normalized = normalize_for_matching(string)

        if Enum.any?(regex_patterns, &String.match?(normalized, &1)) or
             Enum.any?(regex_patterns, &String.match?(String.replace(normalized, "rn", "m"), &1)) do
          {:reject, :confusable}
        end

      true ->
        nil
    end
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
