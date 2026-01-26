# Copyright © 2026 Bonfire Contributors <https://bonfirenetworks.org/>
# Copyright © 2017-2025 Pleroma & Akkoma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.MRF.KeywordPolicy do
  alias ActivityPub.MRF
  alias ActivityPub.Config
  alias ActivityPub.Object

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

  defp string_matches?(string, pattern) when is_binary(pattern) do
    String.contains?(string, pattern) or
      String.contains?(ExConfusables.skeleton(string), pattern)
  end

  defp string_matches?(string, pattern) do
    String.match?(string, pattern) or
      String.match?(ExConfusables.skeleton(string), pattern)
  end

  defp object_payload(%{} = object) do
    [object["content"], object["summary"], object["name"]]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp check_reject(%{"object" => %{} = object} = message) do
    with {:ok, _new_object} <-
           Object.apply_to_object_and_history(object, fn object ->
             payload = object_payload(object)

             if Enum.any?(Config.get([:mrf_keyword, :reject]), fn pattern ->
                  string_matches?(payload, pattern)
                end) do
               {:reject, "[KeywordPolicy] Matches with rejected keyword"}
             else
               {:ok, message}
             end
           end) do
      {:ok, message}
    else
      e -> e
    end
  end

  defp check_ftl_removal(%{"type" => "Create", "to" => to, "object" => %{} = object} = message) do
    check_keyword = fn object ->
      payload = object_payload(object)

      if Enum.any?(Config.get([:mrf_keyword, :federated_timeline_removal]), fn pattern ->
           string_matches?(payload, pattern)
         end) do
        {:should_delist, nil}
      else
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
