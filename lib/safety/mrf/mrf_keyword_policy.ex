# Copyright © 2026 Bonfire Contributors <https://bonfirenetworks.org/>
# Copyright © 2017-2025 Pleroma & Akkoma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.MRF.KeywordPolicy do
  alias ActivityPub.MRF
  alias ActivityPub.Config
  import ActivityPub.Config
  alias ActivityPub.Object
  alias ActivityPub.MRF.KeywordMatcher
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
  #         key: :unlisted_from_feeds,
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

  defp match_type_message(:exact), do: "[KeywordPolicy] Matches rejected keyword"

  defp match_type_message(:confusable),
    do: "[KeywordPolicy] Matches rejected keyword (confusable/homoglyph detected)"

  # the fields a reader sees, matched as visible text by `KeywordMatcher`
  defp object_fields(%{} = object), do: [object["content"], object["summary"], object["name"]]

  defp check_reject(%{"object" => %{} = object} = message, mrf_keyword, confusables_enabled) do
    compiled = compiled(mrf_keyword, :reject)

    with {:ok, _new_object} <-
           Object.apply_to_object_and_history(object, fn object ->
             case find_matching_pattern(object_fields(object), compiled, confusables_enabled) do
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

  # `{:reject, :exact}` when the keywords match the text as written, `{:reject, :confusable}` when they match only once look-alike characters are folded, else `false`. One match for the usual post, which matches nothing; a second only to tell which kind of match it was
  defp find_matching_pattern(fields, compiled, confusables_enabled) do
    cond do
      not KeywordMatcher.match?(compiled, fields, confusables: confusables_enabled) ->
        false

      confusables_enabled and not KeywordMatcher.match?(compiled, fields, confusables: false) ->
        {:reject, :confusable}

      true ->
        {:reject, :exact}
    end
  end

  # A list compiled once, not on every activity: Bonfire's settings hook already stores it as `reject_compiled` for the `reject` list; otherwise compiled here and kept by the hash of the list. Lists change rarely (an admin edits them), so few terms ever accumulate.
  defp compiled(mrf_keyword, :reject) do
    case mrf_keyword[:reject_compiled] do
      %{regex: _, regexes: _} = compiled -> compiled
      _ -> compiled_list(mrf_keyword[:reject])
    end
  end

  defp compiled(mrf_keyword, key), do: compiled_list(mrf_keyword[key])

  defp compiled_list(keywords) do
    case List.wrap(keywords) do
      [] ->
        nil

      keywords ->
        key = {__MODULE__, :compiled, :erlang.phash2(keywords), keywords}

        case :persistent_term.get(key, :not_compiled) do
          :not_compiled ->
            compiled = KeywordMatcher.compile(keywords)
            :persistent_term.put(key, compiled)
            compiled

          compiled ->
            compiled
        end
    end
  end

  defp check_ftl_removal(
         %{"type" => "Create", "to" => to_raw, "object" => %{} = object} = message,
         mrf_keyword,
         confusables_enabled
       ) do
    to = normalize_recipients(to_raw)

    compiled = compiled(mrf_keyword, :unlisted_from_feeds)

    check_keyword = fn object ->
      case find_matching_pattern(object_fields(object), compiled, confusables_enabled) do
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

  defp check_ftl_removal(message, _mrf_keyword, _confusables_enabled) do
    {:ok, message}
  end

  defp check_replace(%{"object" => %{} = object} = message, mrf_keyword) do
    replace_kw = fn object ->
      ["content", "name", "summary"]
      |> Enum.filter(fn field -> Map.has_key?(object, field) && object[field] end)
      |> Enum.reduce(object, fn field, object ->
        data =
          Enum.reduce(
            mrf_keyword[:replace] || [],
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
  def filter(activity, opts \\ [])

  def filter(%{"type" => type, "object" => object} = activity, opts)
      when is_in(type, ["Create", "Update"]) and
             (is_map_key(object, "content") or is_map_key(object, "name") or
                is_map_key(object, "summary")) do
    # local posts are checked against the same list when they are published or edited (and kept to their author when they match), before they can federate
    if is_list(opts) and opts[:is_local] == true,
      do: {:ok, activity},
      else: filter_remote(activity)
  end

  def filter(activity, _opts), do: {:ok, activity}

  defp filter_remote(activity) do
    mrf_keyword = Config.get(:mrf_keyword, [])

    confusables_enabled =
      case mrf_keyword[:detect_confusables] do
        nil -> true
        bool -> bool
      end

    with {:ok, activity} <- check_reject(activity, mrf_keyword, confusables_enabled),
         {:ok, activity} <- check_ftl_removal(activity, mrf_keyword, confusables_enabled),
         {:ok, activity} <- check_replace(activity, mrf_keyword) do
      {:ok, activity}
    else
      {:reject, nil} -> {:reject, "[KeywordPolicy] "}
      {:reject, _} = e -> e
      _e -> {:reject, "[KeywordPolicy] "}
    end
  end

  defp normalize_recipients(recipients) do
    recipients
    |> List.wrap()
    |> Enum.map(fn
      %{ap_id: ap_id} when is_binary(ap_id) -> ap_id
      %{"id" => id} when is_binary(id) -> id
      s when is_binary(s) -> s
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

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
