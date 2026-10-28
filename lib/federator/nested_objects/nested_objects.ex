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
  alias ActivityPub.Object
  alias ActivityPub.Safety
  alias ActivityPub.Safety.IntegrityProofs

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

  # what `reembed/2` looks fields up in: a stored row has lost its own `@context`
  @activitystreams_context "https://www.w3.org/ns/activitystreams"

  @doc """
  Options: `:context` (the `@context` of the document the object is nested in, which applies when the object has none of its own), `:include_fields` and `:exclude_fields` (fields to ingest, or to leave alone, for this call, winning over the context and the config), `:fetch_remote?` (default `true`; with `false` nobody is asked and each embedded copy is stored as it came), `:to` (the audience a stored embedded copy is given when it has none, default the object's own), and the options of `ActivityPub.Federator.Fetcher.fetch_object_from_id/2`.

  What a nested object is stored as is settled here: a copy we fetched is `:fetched`, an embedded copy is `:unverified`, whatever the options say about the document that carried it.
  """
  def ingest(object, options \\ []) do
    {context, options} = Keyword.pop(options, :context)
    {field_options, options} = Keyword.split(options, [:include_fields, :exclude_fields])

    # how the document carrying the nested objects was authenticated: it vouches for a nested object of the same owner or origin, and is never stored as a nested object's own
    wrapper = {options[:authenticated], options[:signed_by]}

    options =
      options
      |> Keyword.drop(@delivery_marks)
      |> Keyword.put_new(:to, object["to"] || object["cc"] || object["audience"] || [])

    policies = Terms.policies(object, context, field_options)

    Enum.reduce(object, object, fn {key, value}, acc ->
      with policy when not is_nil(policy) <- policies[key],
           {:ok, ids} <- detect_and_store(value, policy, wrapper, options) do
        Map.put(acc, key, ids)
      else
        _ -> acc
      end
    end)
  end

  @doc """
  The inverse of `ingest/2`, for a copy of somebody else's object built from the row we hold (`row`) to send on: each field `ingest/2` would have looked in that holds the id of a nested object we hold is given the object back, as its author sent it, in place. Never asks anybody: an id we do not hold stays an id, and so does one we hold only because we fetched it (the author sent an id there). A nested object that kept its original (its own proof held) is given as that original, so the proof still verifies.

  The fields are those of the ActivityStreams context and the configured ones (`Terms.policies/3` given that context), as a stored row has lost its own `@context`: a term only another context defines stays an id. Our own objects are returned as they are, and so is a document that kept its own original, which a caller sends instead.
  """
  def reembed(data, %Object{local: false}) when is_map(data) do
    data
    |> Terms.policies(@activitystreams_context)
    |> Map.keys()
    |> Enum.reduce(data, fn field, acc ->
      case acc do
        %{^field => value} -> Map.put(acc, field, reembed_value(value))
        _ -> acc
      end
    end)
  end

  def reembed(data, _row), do: data

  defp reembed_value(ids) when is_list(ids), do: Enum.map(ids, &reembed_value/1)

  defp reembed_value(id) when is_binary(id) do
    case Object.normalize(id, false) do
      %Object{local: false, authenticated: authenticated} = held
      when authenticated not in [nil, :fetched] ->
        held.data_received || held.data

      _ ->
        id
    end
  end

  defp reembed_value(other), do: other

  defp detect_and_store(value, policy, wrapper, options) when is_list(value) do
    # Handle arrays of potential AP objects
    {:ok,
     Enum.map(value, fn item ->
       case detect_and_store(item, policy, wrapper, options) do
         {:ok, id} ->
           id

         _ ->
           # fallback to preserving existing data
           item
       end
     end)}
  end

  defp detect_and_store(%{"id" => id, "type" => type} = value, policy, wrapper, options)
       when is_binary(id) and (is_binary(type) or is_list(type)) do
    # Check if this looks like an AP object with an ID and type
    if Config.known_fetchable_type?(type) do
      case authentication(value, wrapper) do
        nil -> not_vouched_for(id, value, policy, options)
        authenticated -> store_embedded(value, authenticated, options)
      end
    else
      :skip
    end
  end

  defp detect_and_store(_value, _policy, _wrapper, _options), do: :skip

  # Vouched for with no request: by its own proof, by a wrapper authenticated as its owner, or by a wrapper authenticated as an actor of the same origin as its id (FEP-fe34: an origin vouches for its own objects). `nil` when none of these
  defp authentication(%{"id" => id} = object, {wrapper_authenticated, wrapper_signed_by}) do
    owner = Object.actor_from_data(object)
    wrapper_vouched? = Safety.vouched?(wrapper_authenticated) and is_binary(wrapper_signed_by)

    cond do
      IntegrityProofs.has_proof?(object) and match?({:valid, _}, IntegrityProofs.check(object)) ->
        :integrity_proof

      wrapper_vouched? and owner == wrapper_signed_by ->
        wrapper_authenticated

      wrapper_vouched? and same_host?(id, wrapper_signed_by) ->
        wrapper_authenticated

      true ->
        nil
    end
  end

  defp same_host?(one, two), do: URI.parse(one).host == URI.parse(two).host

  # what the field's policy says to do with a nested object nobody vouched for. Refused, nothing is stored and the field keeps its id, so a consumer can still fetch it
  defp not_vouched_for(id, value, policy, options) do
    fetch? =
      policy in [:authenticate_or_fetch_or_store, :authenticate_or_fetch_or_drop] and
        Keyword.get(options, :fetch_remote?, true) != false

    store? = policy in [:authenticate_or_store, :authenticate_or_fetch_or_store]

    cond do
      fetch? ->
        case fetch(id, options) do
          {:ok, fetched} -> {:ok, id_of(fetched)}
          _ when store? -> store_embedded(value, :unfetchable, options)
          _ -> {:ok, id}
        end

      store? ->
        store_embedded(value, :unverified, options)

      true ->
        {:ok, id}
    end
  end

  defp id_of(%Actor{ap_id: id}), do: id
  defp id_of(%{data: %{"id" => id}}), do: id

  defp fetch(id, options) do
    case Fetcher.fetch_object_from_id(
           id,
           Keyword.put(options, :triggered_by, "NestedObjects.fetch")
         ) do
      {:ok, %ActivityPub.Object{} = fetched} ->
        debug(fetched, "Fetched Object from ActivityPub")
        {:ok, fetched}

      {:ok, %ActivityPub.Actor{} = fetched} ->
        debug(fetched, "Fetched Actor from ActivityPub")
        {:ok, fetched}

      e ->
        debug(e, "Could not fetch the nested object")
        e
    end
  end

  defp store_embedded(embedded_object, authenticated, options) do
    # one vouched for by its own signature is stored with the original it arrived as, the `to` we add below being ours, so its signature still verifies when it goes out again (`reembed/2`); the parent's original is not its own
    options =
      if authenticated in [:integrity_proof, :ld_signature],
        do: Keyword.put(options, :data_received, embedded_object),
        else: Keyword.delete(options, :data_received)

    case embedded_object
         |> Map.put_new("to", options[:to] || [])
         |> Fetcher.cached_or_handle_incoming(
           options
           |> Keyword.put(:authenticated, authenticated)
           |> Keyword.put(:triggered_by, "NestedObjects.store_embedded")
         )
         |> debug("Handled incoming for created embedded object") do
      {:ok, %{} = stored} ->
        {:ok, id_of(stored)}

      e ->
        err(e, "Could not insert embedded data as Object, falling back to using as-is")
        :skip
    end
  end
end
