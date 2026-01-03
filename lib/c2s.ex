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

  @addressing_fields ["to", "cc", "bto", "bcc", "audience"]

  @doc """
  Handles POST requests to /actors/:username/outbox for C2S API.

  Validates the authenticated user matches the actor, prepares the activity,
  and routes through `Transformer.handle_incoming` with `local: true`.
  """
  def handle_c2s_activity(conn, %{"username" => username} = params) do
    current_actor = conn.assigns[:current_actor]

    with true <- not is_nil(current_actor) || {:error, :unauthorized},
         true <-
           validate_actor_match?(current_actor, username) ||
             error(:actor_mismatch, "Actor does not match authenticated user") do
      params
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
    |> Map.put("id", Utils.generate_object_id())
    |> ensure_object_id()
  end

  defp ensure_object_id(%{"type" => "Create", "object" => object} = params) when is_map(object) do
    Map.update!(params, "object", fn obj ->
      obj
      |> Map.put("id", Utils.generate_object_id())
    end)
  end

  defp ensure_object_id(params), do: params

  @doc """
  Per spec: copy addressing between activity and nested object bidirectionally.
  Uses put_new so existing values are preserved.
  """
  defp copy_addressing(%{"type" => "Create", "object" => object} = params) when is_map(object) do
    # Build merged addressing (activity values take precedence, then object values)
    merged =
      @addressing_fields
      |> Enum.map(fn field -> {field, params[field] || object[field]} end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    params
    |> Map.merge(merged)
    |> Map.update!("object", &Map.merge(&1, merged))
  end

  defp copy_addressing(params), do: params

  @doc """
  Wraps a bare object (like a Note) in a Create activity if needed.
  """
  def maybe_wrap_object_in_create(%{"type" => type} = params)
      when not ActivityPub.Config.is_in(type, :supported_activity_types) and
             not ActivityPub.Config.is_in(type, :supported_intransitive_types) do
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
      {:ok, activity}
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

  defp validate_actor_match?(%{username: actor_username}, username) when is_binary(username) do
    actor_username == username
  end

  defp validate_actor_match?(_, _), do: false
end
