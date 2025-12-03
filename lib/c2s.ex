defmodule ActivityPub.C2S do
  @moduledoc """
  Handles ActivityPub Client-to-Server (C2S) protocol.

  Processes incoming C2S activities by validating the authenticated actor,
  preparing the activity data, and routing through the standard ActivityPub
  processing pipeline via `Transformer.handle_incoming`.
  """

  use Untangle
  require ActivityPub.Config
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Utils

  @doc """
  Handles POST requests to /actors/:username/outbox for C2S API.

  Validates the authenticated user matches the actor, prepares the activity,
  and routes through `Transformer.handle_incoming` with `local: true`.
  """
  def handle_c2s_activity(conn, %{"username" => username} = params) do
    current_actor = conn.assigns[:current_actor]
    # current_user = conn.assigns[:current_user]

    with true <- not is_nil(current_actor) || {:error, :unauthorized},
         true <- validate_actor_match?(current_actor, username) || {:error, :actor_mismatch} do
      params
      |> maybe_wrap_object_in_create()
      |> ensure_actor(current_actor)
      |> ensure_ids()
      |> process_activity(current_actor)
    end
  end

  defp ensure_actor(params, current_actor) do
    case Map.get(params, "actor") do
      nil -> Map.put(params, "actor", current_actor.ap_id)
      _existing -> params
    end
  end

  defp ensure_ids(params),
    do:
      params
      |> maybe_put_id()
      |> ensure_object_id()

  @doc """
  Ensures the nested object has an ID per C2S spec:
  "For non-transient objects, the server MUST attach an id to both the wrapping Create and its wrapped Object."
  """
  defp ensure_object_id(%{"type" => "Create", "object" => object} = params) when is_map(object) do
    Map.put(params, "object", maybe_put_id(object))
  end

  defp ensure_object_id(params), do: params

  defp maybe_put_id(map, key \\ "id") do
    case Map.get(map, key) do
      nil -> Map.put(map, key, Utils.generate_object_id())
      _existing -> map
    end
  end

  @doc """
  Wraps a bare object (like a Note) in a Create activity if needed.
  """
  def maybe_wrap_object_in_create(%{"type" => type} = params)
      when not ActivityPub.Config.is_in(type, :supported_activity_types) and
             not ActivityPub.Config.is_in(type, :supported_intransitive_types) do
    %{
      "type" => "Create",
      "actor" => params["actor"] || params["attributedTo"],
      "to" => params["to"],
      "cc" => params["cc"],
      "bto" => params["bto"],
      "bcc" => params["bcc"],
      "object" => params
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  def maybe_wrap_object_in_create(params), do: params

  defp process_activity(%{"type" => _} = params, current_actor) do
    # Route through the standard incoming activity handler with local: true
    # This reuses all existing activity handling logic
    with {:ok, %{local: true} = activity} <-
           Transformer.handle_incoming(params, local: true, current_actor: current_actor) do
      {:ok, activity}
    else
      {:ok, %{local: false} = activity} ->
        err(activity, "C2S activity was not marked as local")

      e ->
        err(e, "C2S activity processing failed")
    end
  end

  defp process_activity(params, current_actor) do
    error(params, "Invalid activity format, missing 'type' field")
    {:error, :invalid_activity}
  end

  defp validate_actor_match?(%{username: actor_username}, username) when is_binary(username) do
    actor_username == username
  end

  defp validate_actor_match?(_, _), do: false
end
