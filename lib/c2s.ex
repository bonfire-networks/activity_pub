defmodule ActivityPub.C2S do
  @moduledoc """
  Handles ActivityPub Client-to-Server (C2S) protocol.

  Processes incoming C2S activities by validating the authenticated actor,
  preparing the activity data, and routing through the standard ActivityPub
  processing pipeline via `Transformer.handle_incoming`.
  """

  use Untangle
  import ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Utils

  @addressing_fields ["to", "cc", "bto", "bcc", "audience"]

  @doc """
  Authorize and process a POST to an actor's outbox.

  `params` are the outbox route's params (which name the outbox), `document` is the posted activity
  (read from the request body, never the merged params — see `handle_c2s_activity/3`). Pass the
  authenticated `current_actor:` and whether the request carried a verified `valid_signature:`.
  """
  def handle_outbox_post(params, document, opts \\ []) do
    with {:ok, %Actor{} = actor, delegation} <-
           authorize_outbox(params, opts[:current_actor], opts) do
      handle_c2s_activity(actor, document, delegation_opts(delegation))
    end
  end

  defp delegation_opts(nil), do: []

  defp delegation_opts(%{user: user, delegated_from: signer_ap_id}),
    do: [current_user: user, delegated_from: signer_ap_id]

  @doc """
  Who may publish through an actor's outbox, given the outbox route's params.

  The outbox belongs to the actor named in the path, so only they may write to it. Because the outbox POST routes share the inbox's HTTP signature pipeline, the authenticated actor can be a REMOTE peer which is not a C2S client, and is refused unless the host app delegates that signer to publish as this actor (the optional `maybe_delegated_user/2` adapter callback, which returns the local identity to act as).

  Pass `valid_signature: true` when the request carried a verified HTTP signature.

  Returns `{:ok, actor_to_publish_as, delegation}`, where `delegation` is nil for an actor posting to their own outbox, or `%{user: local_user, delegated_from: signer_ap_id}` for a delegated signer.
  """
  def authorize_outbox(params, current_actor, opts \\ []) do
    current_actor = as_actor(current_actor)

    # the common case is a client posting to its own outbox, where the path names the actor we already hold, no need to resolve it again
    if authenticated_as?(current_actor, params) do
      {:ok, current_actor, nil}
    else
      with {:ok, %Actor{} = outbox_owner} <- outbox_owner(params) do
        authorize_publisher(outbox_owner, current_actor, opts)
      end
    end
  end

  # who may publish as the actor whose outbox this is
  defp authorize_publisher(%Actor{local: true} = owner, %Actor{} = current, opts) do
    cond do
      authenticated_as?(current, owner) ->
        {:ok, owner, nil}

      current.local ->
        warn(Utils.ap_id(current), "Refusing C2S post to another local actor's outbox")
        {:error, :actor_mismatch}

      opts[:valid_signature] == true ->
        authorize_delegated_signer(owner, current)

      true ->
        warn(Utils.ap_id(current), "Refusing C2S post from an unsigned non-local actor")
        {:error, :unauthorized}
    end
  end

  defp authorize_publisher(%Actor{local: true}, _no_current_actor, _opts) do
    {:error, :unauthorized}
  end

  defp authorize_publisher(%Actor{} = owner, _current_actor, _opts) do
    warn(Utils.ap_id(owner), "Refusing C2S post to a remote actor's outbox")
    {:error, :unauthorized}
  end

  # An authenticated actor normally arrives as an `Actor` (that is what the signature and session plugs assign), but this module has always accepted any shape `Utils.ap_id/1` understands, and the checks below need the real thing to read `local` from.
  defp as_actor(%Actor{} = actor), do: actor
  defp as_actor(nil), do: nil

  defp as_actor(other) do
    with ap_id when is_binary(ap_id) <- Utils.ap_id(other),
         {:ok, %Actor{} = actor} <- Actor.get_cached(ap_id: ap_id) do
      actor
    else
      _ ->
        warn(other, "Could not resolve the authenticated actor")
        nil
    end
  end

  # Is `ref` the authenticated actor? Asked of an outbox route's params (which name the outbox), of a resolved `Actor`, and of an actor URI declared in a posted document, same question each time.
  defp authenticated_as?(nil, _ref), do: false

  defp authenticated_as?(%Actor{local: true, username: username}, %{"username" => path_username})
       when is_binary(username),
       do: username == path_username

  defp authenticated_as?(%Actor{local: true, pointer_id: pointer_id}, %{"actor_id" => actor_id})
       when is_binary(pointer_id),
       do: pointer_id == actor_id

  # a remote actor never owns an outbox here, and route params carry no AP id to compare
  defp authenticated_as?(_current, %{"username" => _}), do: false
  defp authenticated_as?(_current, %{"actor_id" => _}), do: false

  # `current_actor` is not always an `Actor` struct (`ensure_actor/2` accepts several shapes), so compare whatever AP ids the two sides can produce
  defp authenticated_as?(current, ref) do
    with current_ap_id when is_binary(current_ap_id) <- Utils.ap_id(current),
         ref_ap_id when is_binary(ref_ap_id) <- Utils.ap_id(ref) do
      current_ap_id == ref_ap_id
    else
      _ -> false
    end
  end

  defp outbox_owner(%{"actor_id" => actor_id}), do: Actor.get_cached(pointer: actor_id)
  defp outbox_owner(%{"username" => username}), do: Actor.get_cached(username: username)
  defp outbox_owner(_params), do: {:error, :not_found}

  defp authorize_delegated_signer(owner, signer) do
    case Adapter.call_or(:maybe_delegated_user, [owner, signer], nil) do
      nil ->
        warn(Utils.ap_id(signer), "Refusing C2S post from an undelegated remote signer")
        {:error, :unauthorized}

      delegated_user ->
        info(
          "C2S: #{Utils.ap_id(signer)} is publishing as #{Utils.ap_id(owner)} (delegated signer)"
        )

        {:ok, owner, %{user: delegated_user, delegated_from: Utils.ap_id(signer)}}
    end
  end

  @doc """
  Handles a C2S activity posted to an actor's outbox.

  The identity is the AUTHENTICATED `current_actor` (established by `authorize_outbox/3`), the `activity` is the raw posted document (from `conn.body_params`, so router path params like the actor's id/username are never injected into it). Rejects a document that tries to attribute itself to a DIFFERENT actor; otherwise stamps `current_actor` as the actor and routes through
  `Transformer.handle_incoming` with `local: true`.

  Pass `delegated_from: <signer ap id>` when the poster is a delegated remote signer rather than the actor's own client, so the document's source URL survives id rewriting.
  """
  def handle_c2s_activity(current_actor, activity, opts \\ []) when is_map(activity) do
    with true <- not is_nil(current_actor) || {:error, :unauthorized},
         true <- authorship_allowed?(activity, current_actor, opts) || actor_mismatch() do
      activity
      |> maybe_wrap_object_in_create()
      |> ensure_actor(current_actor, opts)
      |> ensure_attributed_to(opts)
      |> maybe_keep_source_url(opts)
      |> ensure_ids()
      |> copy_addressing()
      |> process_activity(current_actor, opts)
    end
  end

  # A delegated post was authored on another system, so its id is a real page there. `ensure_ids/1` is about to replace it with a local one, so keep it as `url`, but never clobber a `url` the client sent, which is a better link than the id by definition.
  defp maybe_keep_source_url(%{"type" => "Create", "object" => object} = params, opts)
       when is_map(object) do
    with source when is_binary(source) <- opts[:delegated_from] && object["id"] do
      Map.update!(params, "object", &Map.put_new(&1, "url", source))
    else
      _ -> params
    end
  end

  defp maybe_keep_source_url(params, _opts), do: params

  # the ATOM has to survive to the caller: `error/2` with a message returns `{:error, message}`, and a binary reason reads as a generic bad request rather than this specific refusal
  defp actor_mismatch do
    error(:actor_mismatch, "Activity actor does not match authenticated user")
    {:error, :actor_mismatch}
  end

  # A delegated signer publishes AS the local actor, so whatever authorship the source document declares is ours to replace, not a forgery attempt to refuse.
  defp authorship_allowed?(activity, current_actor, opts),
    do: delegated?(opts) or declared_actors_match?(activity, current_actor)

  defp delegated?(opts), do: is_binary(opts[:delegated_from])

  # only fills in the actor the client omitted — except for a delegated post, whose authorship we own outright
  defp ensure_actor(params, current_actor, opts) do
    case Utils.ap_id(current_actor) do
      ap_id when is_binary(ap_id) ->
        if delegated?(opts),
          do: Map.put(params, "actor", ap_id),
          else: Map.put_new(params, "actor", ap_id)

      _ ->
        params
    end
  end

  # Ensure nested object has attributedTo set to the activity actor
  defp ensure_attributed_to(
         %{"type" => "Create", "object" => object, "actor" => actor} = params,
         opts
       )
       when is_map(object) and is_binary(actor) do
    # for Create we override attributedTo to match actor
    Map.update!(params, "object", fn obj ->
      obj
      |> Map.put("attributedTo", actor)
      |> maybe_replace_object_actor(actor, opts)
    end)
  end

  defp ensure_attributed_to(params, _opts), do: params

  # a delegated source may also name itself in the object's own `actor`, so replace it, but never add one the source didn't have
  defp maybe_replace_object_actor(object, actor, opts) do
    if delegated?(opts) and Map.has_key?(object, "actor"),
      do: Map.put(object, "actor", actor),
      else: object
  end

  # Per spec: servers MUST ignore client-provided IDs and generate new ones
  defp ensure_ids(params) do
    params
    |> Map.put("id", Utils.generate_object_id(&Needle.ULID.generate/0))
    |> ensure_object_id()
  end

  defp ensure_object_id(%{"type" => "Create", "object" => object} = params) when is_map(object) do
    Map.update!(params, "object", fn obj ->
      obj
      |> Map.put("id", Utils.generate_object_id(&Needle.ULID.generate/0))
    end)
  end

  defp ensure_object_id(params), do: params

  # Copy addressing between activity and nested object, unioning both lists.
  defp copy_addressing(%{"type" => "Create", "object" => object} = params) when is_map(object) do
    merged =
      @addressing_fields
      |> Enum.map(fn field ->
        v = List.wrap(params[field]) ++ List.wrap(object[field])
        {field, v |> Enum.uniq() |> Enum.reject(&is_nil/1)}
      end)
      |> Enum.reject(fn {_k, v} -> v == [] end)
      |> Map.new()

    params |> Map.merge(merged) |> Map.update!("object", &Map.merge(&1, merged))
  end

  defp copy_addressing(params), do: params

  @doc """
  Wraps a bare object (like a Note) in a Create activity if needed.
  """
  def maybe_wrap_object_in_create(%{"type" => type} = params)
      when not is_in(type, :supported_activity_types) and
             not is_in(type, :supported_intransitive_types) do
    %{
      "type" => "Create",
      "object" => params
    }
  end

  def maybe_wrap_object_in_create(params), do: params

  defp process_activity(%{"type" => _} = params, current_actor, opts) do
    # Route through the standard incoming activity handler with local: true
    # This reuses all existing activity handling logic
    with {:ok, %{local: true} = activity} <-
           Transformer.handle_incoming(
             params,
             [local: true, from_c2s: true, current_actor: current_actor] ++
               Keyword.take(opts, [:current_user])
           ) do
      # After successful C2S activity, delete activity and object from DB and cache

      # ActivityPub.Object.get_cached(ap_id: activity.data["id"])
      #       |> case do
      #         {:ok, activity} -> {:ok, activity}
      #         e -> 
      #           err(e, "C2S activity created by adapter not found")
      {:ok, activity}
      # end
    else
      {:ok, %{local: false} = activity} ->
        err(activity, "C2S activity was not marked as local")

      {:error, :not_deleted} ->
        {:error, :unauthorized}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      e ->
        err(e, "C2S activity processing failed")
    end
  end

  defp process_activity(params, _current_actor, _opts) do
    error(params, "Invalid activity format, missing 'type' field")
    {:error, :invalid_activity}
  end

  # The posted document may omit an actor (we stamp `current_actor` via `ensure_actor`), but if it DOES declare one (on the activity or its nested object) it must be the authenticated actor: no posting activities attributed to someone else through your own outbox.
  defp declared_actors_match?(activity, current_actor) do
    # `object` may be a bare URI string (e.g. a Like's target), so only look inside it when it's a map
    object = activity["object"]
    nested_actors = if is_map(object), do: [object["actor"], object["attributedTo"]], else: []

    ([activity["actor"], activity["attributedTo"]] ++ nested_actors)
    |> Enum.filter(&is_binary/1)
    |> Enum.all?(&authenticated_as?(current_actor, &1))
  end
end
