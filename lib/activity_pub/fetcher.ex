defmodule ActivityPub.Fetcher do
  @moduledoc """
  Handles fetching AS2 objects from remote instances.
  """

  alias ActivityPub.HTTP
  alias ActivityPub.Object
  alias ActivityPubWeb.Transmogrifier
  import Untangle

  @supported_activity_types ActivityPub.Utils.supported_activity_types()
  @supported_actor_types ActivityPub.Utils.supported_actor_types()

  @doc """
  Checks if an object exists in the database and fetches it if it doesn't.
  """
  def fetch_object_from_id(id) do
    case Object.get_cached_by_ap_id(id) do
      {:ok, actor} -> {:ok, actor}
      _ ->
        fetch_fresh_object_from_id(id)
    end
  end

  def fetch_fresh_object_from_id(%{data: %{"id"=>id}}), do: fetch_fresh_object_from_id(id)
  def fetch_fresh_object_from_id(%{"id"=>id}), do: fetch_fresh_object_from_id(id)
  def fetch_fresh_object_from_id(id) do
        with {:ok, data} <- fetch_remote_object_from_id(id) |> info,
           {:ok, object} <- maybe_store_data(data) do
        {:ok, object}
    end
  end

  defp maybe_store_data(data) do
    with {:ok, object} <- Object.single_by_ap_id(data) do
      info("object was already cached under another ID")
          # TODO: update in some specific cases?
      {:ok, object}
    else _ ->
      with {:ok, data} <- contain_origin(data),
           {:ok, object} <- insert_object(data) do
        #  :ok <- check_if_public(object.public) do # huh?
        {:ok, object}
      else
        e ->
          error(e)
      end
    end
  end

  def get_or_fetch_and_create(id) do
    with {:ok, object} <- fetch_object_from_id(id) do
      with %{data: %{"type" => type}} when type in @supported_actor_types <-
             object do
        {:ok, ActivityPub.Actor.maybe_create_actor_from_object(object)}
      else
        _ ->
          {:ok, object}
      end
    end
  end

  def get_or_fetch_and_create_tuple(id) do
    with {:ok, object} <- fetch_object_from_id(id) do
        ActivityPub.Actor.maybe_create_actor_from_object_tuple(object)
    end
  end

  @doc """
  Fetches an AS2 object from remote AP ID.
  """
  def fetch_remote_object_from_id(id) do
    debug(id, "Attempting to fetch ActivityPub object")

    with true <- String.starts_with?(id, "http"),
         {:ok, %{body: body, status: code}} when code in 200..299 <-
           HTTP.get(
             id,
             [{:Accept, "application/activity+json"}]
           ),
         {:ok, data} <- Jason.decode(body),
         {:ok, data} <- contain_uri(id, data) do
      {:ok, data}
    else
      {:ok, %{status: code}} when code in [404, 410] ->
        warn(id, "404")

        {:error, "Object not found or deleted"}

      %Jason.DecodeError{} = error ->
        error("Invalid AP JSON")

      {:error, :econnrefused} = e ->
        error("Could not connect")

      {:error, e} ->
        error(e)

      e ->
        error(e)
    end
  end

  @skipped_types [
    "Person",
    "Group",
    "Collection",
    "OrderedCollection",
    "CollectionPage",
    "OrderedCollectionPage"
  ]
  defp contain_origin(%{"id" => id} = data) do
    if data["type"] in @skipped_types do
      {:ok, data}
    else
      actor = get_actor(data)
      actor_uri = URI.parse(actor)
      id_uri = URI.parse(id)

      if id_uri.host == actor_uri.host do
        {:ok, data}
      else
        {:error, "Object containment error"}
      end
    end
  end

  # Wrapping object in a create activity to easily pass it to the app's relational database.
  defp insert_object(%{"type" => type} = data)
       when type not in @supported_activity_types and
              type not in @supported_actor_types and type not in ["Collection"] do
    with params <- %{
           "type" => "Create",
           "to" => data["to"],
           "cc" => data["cc"],
           "actor" => get_actor(data),
           "object" => data
         },
         {:ok, activity} <- Transmogrifier.handle_incoming(params),
         object <- Map.get(activity, :object, activity) do
      {:ok, object}
    end
  end

  # QUESTION: does calling handle_object here instead of handle_incoming mean activities (or objects not in @create_object_types) won't be handled in the same way?
  defp insert_object(data), do: Transmogrifier.handle_object(data)

  def get_actor(%{"attributedTo" => actor} = _data), do: actor

  def get_actor(%{"actor" => actor} = _data), do: actor

  def get_actor(%{"id" => actor, "type" => type} = _data)
      when type in @supported_actor_types,
      do: actor

  defp check_if_public(public) when public == true, do: :ok

  # discard for now, to avoid privacy leaks
  defp check_if_public(_public), do: {:error, "Not public"}

  defp contain_uri(id, %{"id" => json_id} = data) do
    id_uri = URI.parse(id)
    json_id_uri = URI.parse(json_id)

    if id_uri.host == json_id_uri.host do
      {:ok, data}
    else
      {:error, "URI containment error"}
    end
  end
end
