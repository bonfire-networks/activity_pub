# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Federator.NestedObjects do
  @moduledoc """
  Stores the objects nested in the fields of another object (an event's `location`, a recipe's `instrument`, a service's `generator`) as objects of their own, and leaves their AP ids in the fields, so the document stays plain ActivityPub and a reader loads each by id.

  Which fields hold objects is read from the document's `@context` (`ActivityPub.Federator.NestedObjects.Terms`). For each nested object in one of them:

    * the copy at its origin is fetched, and wins over the embedded one
    * if that cannot be done, the embedded copy is stored as it came
    * what is not an object of a type we know, or has no `id` to fetch or store under, is left where it is

  What a caller points at the stored objects with is its own business.
  """

  import Untangle

  alias ActivityPub.Actor
  alias ActivityPub.Config
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.NestedObjects.Terms

  # how the document that carries a nested object came to us says nothing about the nested object: a signature covers what was signed, and an object we fetched is not the one embedded in it
  @delivery_marks [
    :authenticated,
    :signed_by,
    :object_authenticated,
    :object_signed_by,
    :from_inbox,
    :already_fetched,
    :relayed_by
  ]

  @doc """
  Options: `:context` (the `@context` of the document the object is nested in, which applies when the object has none of its own), `:include_fields` and `:exclude_fields` (fields to ingest, or to leave alone, for this call, winning over the context and the config), `:fetch_remote?` (default `true`; with `false` nobody is asked and each embedded copy is stored as it came), `:to` (the audience a stored embedded copy is given when it has none, default the object's own), and the options of `ActivityPub.Federator.Fetcher.fetch_object_from_id/2`.

  What a nested object is stored as is settled here: a copy we fetched is `:fetched`, an embedded copy is `:unverified`, whatever the options say about the document that carried it.
  """
  def ingest(object, options \\ []) do
    {context, options} = Keyword.pop(options, :context)
    {include, options} = Keyword.pop(options, :include_fields, [])
    {exclude, options} = Keyword.pop(options, :exclude_fields, [])

    options =
      options
      |> Keyword.drop(@delivery_marks)
      |> Keyword.put_new(:to, object["to"] || object["cc"] || object["audience"] || [])

    fields = Terms.fields(object, context, include: include, exclude: exclude)

    Enum.reduce(object, object, fn {key, value}, acc ->
      with true <- key in fields,
           {:ok, ids} <- detect_and_store(value, options) do
        Map.put(acc, key, ids)
      else
        _ -> acc
      end
    end)
  end

  defp detect_and_store(value, options) when is_list(value) do
    # Handle arrays of potential AP objects
    {:ok,
     Enum.map(value, fn item ->
       case detect_and_store(item, options) do
         {:ok, id} ->
           id

         _ ->
           # fallback to preserving existing data
           item
       end
     end)}
  end

  defp detect_and_store(%{"id" => id, "type" => type} = value, options)
       when is_binary(id) and (is_binary(type) or is_list(type)) do
    # Check if this looks like an AP object with an ID and type
    if Config.known_fetchable_type?(type) do
      with {:ok, stored} <- fetch_or_store_embedded(id, value, options) do
        {:ok, id_of(stored)}
      end
    else
      :skip
    end
  end

  defp detect_and_store(_value, _options), do: :skip

  defp id_of(%Actor{ap_id: id}), do: id
  defp id_of(%{data: %{"id" => id}}), do: id

  defp fetch_or_store_embedded(id, embedded_object, options) do
    if Keyword.get(options, :fetch_remote?, true),
      do: fetch_or_store_embedded_copy(id, embedded_object, options),
      else: store_embedded(embedded_object, options)
  end

  defp fetch_or_store_embedded_copy(id, embedded_object, options) do
    case Fetcher.fetch_object_from_id(
           id,
           Keyword.put(options, :triggered_by, "NestedObjects.fetch_or_store_embedded")
         ) do
      {:ok, %ActivityPub.Object{} = fetched} ->
        debug(fetched, "Fetched Object from ActivityPub")
        {:ok, fetched}

      {:ok, %ActivityPub.Actor{} = fetched} ->
        debug(fetched, "Fetched Actor from ActivityPub")
        {:ok, fetched}

      e ->
        debug(
          e,
          "Could not fetch and/or save embedded object, falling back to using embedded data"
        )

        store_embedded(embedded_object, options)
    end
  end

  defp store_embedded(embedded_object, options) do
    case embedded_object
         |> Map.put_new("to", options[:to] || [])
         |> Fetcher.cached_or_handle_incoming(
           options
           |> Keyword.put(:authenticated, :unverified)
           |> Keyword.put(:triggered_by, "NestedObjects.store_embedded")
         )
         |> debug("Handled incoming for created embedded object") do
      {:ok, %{} = stored} ->
        {:ok, stored}

      e ->
        err(e, "Could not insert embedded data as Object, falling back to using as-is")
        :skip
    end
  end
end
