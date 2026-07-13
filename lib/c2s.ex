defmodule ActivityPub.C2S do
  @moduledoc """
  Handles ActivityPub Client-to-Server (C2S) protocol.

  Processes incoming C2S activities by validating the authenticated actor,
  preparing the activity data, and routing through the standard ActivityPub
  processing pipeline via `Transformer.handle_incoming`.
  """

  use Untangle
  import ActivityPub.Config
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Utils

  @addressing_fields ["to", "cc", "bto", "bcc", "audience"]

  @doc """
  Handles a C2S activity posted to an actor's outbox.

  The identity is the AUTHENTICATED `current_actor` (established by the outbox auth plug) — the
  `activity` is the raw posted document (from `conn.body_params`, so router path params like the
  actor's id/username are never injected into it). Rejects a document that tries to attribute
  itself to a DIFFERENT actor; otherwise stamps `current_actor` as the actor and routes through
  `Transformer.handle_incoming` with `local: true`.
  """
  def handle_c2s_activity(current_actor, activity) when is_map(activity) do
    with true <- not is_nil(current_actor) || {:error, :unauthorized},
         true <-
           actor_not_forged?(activity, current_actor) ||
             error(:actor_mismatch, "Activity actor does not match authenticated user") do
      activity
      |> maybe_wrap_object_in_create()
      |> ensure_actor(current_actor)
      |> ensure_attributed_to()
      |> ensure_ids()
      |> copy_addressing()
      |> process_activity(current_actor)
    end
  end

  defp ensure_actor(params, %{ap_id: ap_id}) do
    Map.put_new(params, "actor", ap_id)
  end

  defp ensure_actor(params, %{data: %{"id" => ap_id}}) do
    Map.put_new(params, "actor", ap_id)
  end

  defp ensure_actor(params, %{"id" => ap_id}) do
    Map.put_new(params, "actor", ap_id)
  end

  # Ensure nested object has attributedTo set to the activity actor
  defp ensure_attributed_to(%{"type" => "Create", "object" => object, "actor" => actor} = params)
       when is_map(object) and is_binary(actor) do
    # for Create we override attributedTo to match actor
    Map.update!(params, "object", &Map.put(&1, "attributedTo", actor))
  end

  defp ensure_attributed_to(params), do: params

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

  defp process_activity(%{"type" => _} = params, current_actor) do
    # Route through the standard incoming activity handler with local: true
    # This reuses all existing activity handling logic
    with {:ok, %{local: true} = activity} <-
           Transformer.handle_incoming(params,
             local: true,
             from_c2s: true,
             current_actor: current_actor
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

  defp process_activity(params, current_actor) do
    error(params, "Invalid activity format, missing 'type' field")
    {:error, :invalid_activity}
  end

  # The posted document may omit an actor (we stamp `current_actor` via `ensure_actor`), but if it
  # DOES declare one — on the activity or its nested object — it must be the authenticated actor:
  # no posting activities attributed to someone else through your own outbox.
  defp actor_not_forged?(activity, current_actor) do
    actor_ap_id = Utils.ap_id(current_actor)

    # `object` may be a bare URI string (e.g. a Like's target), so only look inside it when it's a map
    object = activity["object"]
    nested_actors = if is_map(object), do: [object["actor"], object["attributedTo"]], else: []

    declared =
      ([activity["actor"], activity["attributedTo"]] ++ nested_actors)
      |> Enum.filter(&is_binary/1)

    declared == [] or Enum.all?(declared, &(&1 == actor_ap_id))
  end
end
