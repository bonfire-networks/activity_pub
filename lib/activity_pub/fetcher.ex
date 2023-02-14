defmodule ActivityPub.Fetcher do
  @moduledoc """
  Handles fetching AS2 objects from remote instances.
  """

  alias ActivityPub.Config
  alias ActivityPub.Utils
  alias ActivityPub.HTTP
  alias ActivityPub.Object
  alias ActivityPubWeb.Transmogrifier
  alias ActivityPub.Object.Containment
  alias ActivityPub.Instances

  import Untangle

  @supported_actor_types ActivityPub.Config.supported_actor_types()

  @doc """
  Checks if an object exists in the AP and Adapter databases and fetches and creates it if not.
  """
  def fetch_object_from_id(id, _opts \\ []) do
    case cached_or_handle_incoming(id) do
      {:ok, object} ->
        {:ok, object}

      _ ->
        fetch_fresh_object_from_id(id)
    end
  end

  @doc """
  Checks if an object exists in the AP database and fetches it if not.
  """
  def fetch_ap_object_from_id(id, opts \\ []) do
    case Object.get_cached(ap_id: id) do
      {:ok, object} ->
        {:ok, object}

      _ ->
        fetch_remote_object_from_id(id, opts)
    end
  end

  def fetch_fresh_object_from_id(id, opts \\ [])

  def fetch_fresh_object_from_id(%{data: %{"id" => id}}, opts),
    do: fetch_fresh_object_from_id(id, opts)

  def fetch_fresh_object_from_id(%{"id" => id}, opts), do: fetch_fresh_object_from_id(id, opts)

  def fetch_fresh_object_from_id(id, opts) do
    with {:ok, data} <- fetch_remote_object_from_id(id, opts) |> debug("fetched"),
         {:ok, object} <- cached_or_handle_incoming(data) do
      Instances.set_reachable(id)

      {:ok, object}
    end
  end

  defp cached_or_handle_incoming(id_or_data) do
    case Object.get_cached(ap_id: id_or_data) do
      {:ok, %{pointer_id: nil, data: data} = _object} ->
        warn(
          "seems the object was already cached in object table, but not processed/saved by the adapter"
        )

        handle_incoming(data)
        |> debug("handled")

      {:ok, object} ->
        {:ok, object}

      {:error, :not_found} when is_map(id_or_data) ->
        debug("seems like a new object")

        handle_incoming(id_or_data)
        |> debug("handled")

      other ->
        error(other, "No object found")
    end
  end

  defp handle_incoming(data) do
    with {:ok, object} <- Transmogrifier.handle_incoming(data) do
      #  :ok <- check_if_public(object.public) do # huh?
      case object do
        # return the object rather than a Create activity (do we want this?)
        %{object: %{id: _} = object, pointer: pointer} = activity ->
          {:ok,
           object
           |> Utils.maybe_put(:pointer, pointer)}

        _ ->
          {:ok, object}
      end
    else
      e ->
        error(e)
    end
  end

  @doc """
  Fetches an AS2 object from remote AP ID.
  """
  def fetch_remote_object_from_id(id, options \\ []) do
    debug(id, "Attempting to fetch ActivityPub object")

    with true <- Transmogrifier.allowed_thread_distance?(options[:depth]),
         # If we have instance restrictions, apply them here to prevent fetching from unwanted instances
         {:ok, nil} <- ActivityPub.MRF.SimplePolicy.check_reject(URI.parse(id)),
         true <- String.starts_with?(id, "http"),
         {:ok, %{body: body, status: code}} when code in 200..299 <-
           HTTP.get(
             id,
             [{:Accept, "application/activity+json"}]
           ),
         {:ok, data} <- Jason.decode(body) |> debug(body),
         :ok <- Containment.contain_origin(id, data) |> debug("contain_origin?") do
      {:ok, data}
    else
      {:ok, %{status: 304}} ->
        debug(
          "HTTP I am a teapot - we use this for unavailable mocks in tests - return cached object or ID"
        )

        case Object.get_cached(ap_id: id) do
          {:ok, object} -> {:ok, object}
          _ -> {:ok, id}
        end

      {:ok, %{status: code}} when code in [404, 410] ->
        warn(id, "ActivityPub remote replied with 404")
        {:error, "Object not found or deleted"}

      %Jason.DecodeError{} = error ->
        error("Invalid ActivityPub JSON")

      {:error, :econnrefused} = e ->
        error("Could not connect to ActivityPub remote")

      {:error, e} ->
        error(e)

      {:ok, %{status: code} = e} ->
        error(e, "ActivityPub remote replied with HTTP #{code}")

      {:reject, e} ->
        {:reject, e}

      e ->
        error(e, "Error trying to connect with ActivityPub remote")
    end
  end

  defp check_if_public(public) when public == true, do: :ok

  # discard for now, to avoid privacy leaks
  defp check_if_public(_public), do: {:error, "Not public"}

  @spec fetch_collection(String.t() | map()) :: {:ok, [Object.t()]} | {:error, any()}
  def fetch_collection(ap_id) when is_binary(ap_id) do
    with {:ok, page} <- fetch_object_from_id(ap_id) do
      {:ok, objects_from_collection(page)}
    else
      e ->
        error(e, "Could not fetch collection #{ap_id}")
        e
    end
  end

  def fetch_collection(%{"type" => type} = page)
      when type in ["Collection", "OrderedCollection", "CollectionPage", "OrderedCollectionPage"] do
    {:ok, objects_from_collection(page)}
  end

  defp items_in_page(%{"type" => type, "orderedItems" => items})
       when is_list(items) and type in ["OrderedCollection", "OrderedCollectionPage"],
       do: items

  defp items_in_page(%{"type" => type, "items" => items})
       when is_list(items) and type in ["Collection", "CollectionPage"],
       do: items

  defp objects_from_collection(%{"type" => type, "orderedItems" => items} = page)
       when is_list(items) and type in ["OrderedCollection", "OrderedCollectionPage"],
       do: maybe_next_page(page, items)

  defp objects_from_collection(%{"type" => type, "items" => items} = page)
       when is_list(items) and type in ["Collection", "CollectionPage"],
       do: maybe_next_page(page, items)

  defp objects_from_collection(%{"type" => type, "first" => first})
       when is_binary(first) and type in ["Collection", "OrderedCollection"] do
    fetch_page(first)
  end

  defp objects_from_collection(%{"type" => type, "first" => %{"id" => id}})
       when is_binary(id) and type in ["Collection", "OrderedCollection"] do
    fetch_page(id)
  end

  defp objects_from_collection(_page), do: []

  defp fetch_page(page_id, items \\ []) do
    if Enum.count(items) >= Config.get([:activitypub, :max_collection_objects]) do
      items
    else
      with {:ok, page} <- fetch_object_from_id(page_id) do
        objects = items_in_page(page)

        if Enum.count(objects) > 0 do
          maybe_next_page(page, items ++ objects)
        else
          items
        end
      else
        {:error, "Object not found or deleted"} ->
          items

        {:error, error} ->
          error(error, "Could not fetch page #{page_id}")
          {:error, error}
      end
    end
  end

  defp maybe_next_page(%{"next" => page_id}, items) when is_binary(page_id) do
    fetch_page(page_id, items)
  end

  defp maybe_next_page(_, items), do: items
end
