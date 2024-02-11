defmodule ActivityPub.Federator.Fetcher do
  @moduledoc """
  Handles fetching AS2 objects from remote instances.
  """

  require ActivityPub.Config

  alias ActivityPub.Config
  alias ActivityPub.Utils
  alias ActivityPub.Federator.HTTP
  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Safety.Containment
  alias ActivityPub.Instances
  alias ActivityPub.Federator.Workers
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Federator.Adapter

  import Untangle

  @doc """
  Checks if an object exists in the AP database and fetches it if not (but does not send to Adapter).
  """
  # TODO: deduplicate this and fetch_object_from_id/2
  def get_cached_object_or_fetch_ap_id(id, opts \\ []) do
    case Object.get_cached(ap_id: id) do
      {:ok, object} ->
        {:ok, object}

      _ ->
        fetch_remote_object_from_id(id, opts)
    end
  end

  @doc """
  Checks if an object exists in the AP database and prepares it if not (local objects only).
  """
  def get_cached_object_or_fetch_pointer_id(pointer, opts \\ []) do
    Object.get_cached(pointer: pointer)
    |> maybe_handle_incoming(pointer, opts)
  end

  @doc """
  Checks if an object exists in the AP and Adapter databases and fetches and creates it if not.
  """
  def fetch_object_from_id(id, opts \\ []) do
    case cached_or_handle_incoming(id, opts) |> debug("cohi") do
      {:ok, object} ->
        {:ok, object}

      _ ->
        fetch_fresh_object_from_id(id, opts)
    end
  end

  def fetch_objects_from_id(ids, opts \\ []) when is_list(ids) do
    Enum.take(ids, max_recursion())
    |> Enum.map(fn id ->
      with {:ok, object} <- fetch_object_from_id(id, opts) do
        object
      else
        e ->
          error(e)
          nil
      end
    end)
  end

  def maybe_fetch(entries, opts \\ [])
  def maybe_fetch([], _opts), do: nil

  def maybe_fetch(entries, opts) when is_list(entries) do
    depth = (opts[:depth] || 0) + 1
    max_items = Config.get([:instance, :federation_incoming_max_items]) || 5

    if allowed_recursion?(depth) do
      case opts[:mode] do
        false ->
          debug("skip because of mode: false")
          nil

        mode when mode in [:async, nil] ->
          for {id, index} <- Enum.with_index(entries) do
            entry_depth = depth + index

            if allowed_recursion?(entry_depth, max_items) do
              enqueue_fetch(
                id,
                Enum.into(opts[:worker_attrs] || %{}, %{
                  "depth" => entry_depth,
                  "fetch_collection_entries" => opts[:fetch_collection_entries]
                })
              )
            end
          end

          nil

        true ->
          for {id, index} <- Enum.with_index(entries) do
            entry_depth = depth + index

            if allowed_recursion?(entry_depth, max_items) do
              fetch_object_from_id(id,
                depth: entry_depth
              )
            end
          end

        other ->
          debug(other, "skip because of mode")
          nil
      end
    else
      debug(depth, "skip because of recursion limits")
      nil
    end
  end

  def maybe_fetch(entries, opts), do: maybe_fetch(List.wrap(entries), opts)

  def enqueue_fetch(id, worker_attrs \\ %{}) do
    Workers.RemoteFetcherWorker.enqueue(
      "fetch_remote",
      Enum.into(worker_attrs || %{}, %{
        "id" => id
      })
    )
  end

  def fetch_fresh_object_from_id(id, opts \\ [])

  def fetch_fresh_object_from_id(%{data: %{"id" => id}}, opts),
    do: fetch_fresh_object_from_id(id, opts)

  def fetch_fresh_object_from_id(%{"id" => id}, opts), do: fetch_fresh_object_from_id(id, opts)

  def fetch_fresh_object_from_id(id, opts) do
    # raise "STOOOP"
    with true <- String.starts_with?(id, "http"),
         false <- String.starts_with?(id, ActivityPub.Web.base_url()),
         {:ok, data} <- fetch_remote_object_from_id(id, opts) |> debug("QUQUQUQUQU"),
         {:ok, object} <- cached_or_handle_incoming(data, opts) do
      {:ok, object}
    else
      true ->
        warn("seems we're trying to fetch a local actor, looking it up from the adapter...")
        Adapter.get_actor_by_ap_id(id)

      other ->
        error(other)
    end
  end

  defp cached_or_handle_incoming(%{"type" => type} = id_or_data, opts)
       when ActivityPub.Config.is_in(type, :supported_actor_types) do
    debug("create/update an Actor")
    handle_fetched(id_or_data, opts)
  end

  defp cached_or_handle_incoming(id_or_data, opts) do
    Object.get_cached(ap_id: id_or_data)
    |> debug("gcc")
    |> maybe_handle_incoming(id_or_data, opts)
  end

  defp maybe_handle_incoming(input, id_or_data, opts) do
    case input do
      # {:ok, %{local: true}} ->
      #   debug("local object so don't treat as incoming")
      #   {:ok, input}

      {:ok, %{pointer_id: nil, data: data} = _object} ->
        warn(
          "seems the object was already cached in object table, but not processed/saved by the adapter"
        )

        handle_fetched(data, opts)
        |> debug("handled")

      {:ok, _} ->
        input

      {:error, :not_found} when is_map(id_or_data) ->
        case id_or_data do
          %{local: true} ->
            debug("local object so don't treat as incoming")
            {:ok, id_or_data}

          _ ->
            debug("seems like a new object")

            handle_fetched(id_or_data, opts)
            |> debug("handled")
        end

      {:error, :not_found} ->
        warn(id_or_data, "No such object has been cached")

      other ->
        error(other)
    end
  end

  defp handle_fetched(%{data: data}, opts), do: handle_fetched(data, opts)

  defp handle_fetched(data, opts) do
    debug(opts)

    with {:ok, object} <- Transformer.handle_incoming(data, opts) |> debug() do
      #  :ok <- check_if_public(object.public) do # huh?
      skip_fetch_collection? = !opts[:fetch_collection]
      skip_fetch_collection_entries? = !opts[:fetch_collection_entries]

      case object do
        %Actor{data: %{"outbox" => outbox}}
        when is_binary(outbox) and skip_fetch_collection? == false ->
          debug(
            outbox,
            "An actor was fetched, fetch outbox collection (and maybe queue a fetch of entries as well)"
          )

          fetch_collection(outbox, mode: opts[:fetch_collection])

          {:ok, object}

        %{data: %{"type" => type} = collection}
        when ActivityPub.Config.is_in(type, :collection_types)
        when skip_fetch_collection_entries? == false ->
          debug(
            opts[:fetch_collection_entries],
            "A collection was fetched, queue a fetch of entries as well"
          )

          handle_collection(collection, mode: opts[:fetch_collection_entries])

          {:ok, object}

        # return the object rather than a Create activity (do we want this?)
        %{object: %{id: _} = object, pointer: pointer} = _activity ->
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

  def fetch_outbox(actor, opts \\ [fetch_collection: :async])

  def fetch_outbox(%{data: %{"outbox" => outbox}}, opts) do
    fetch_outbox(%{"outbox" => outbox}, opts)
  end

  def fetch_outbox(%{"outbox" => outbox}, opts) when is_binary(outbox) do
    debug(
      outbox,
      "fetch outbox collection (and maybe queue a fetch of entries as well)"
    )

    fetch_collection(outbox, mode: opts[:fetch_collection])
  end

  def fetch_outbox(other, opts) do
    with {:ok, %{data: %{"outbox" => outbox}}} when is_binary(outbox) <-
           Actor.get_cached(other) do
      fetch_outbox(%{"outbox" => outbox}, opts)
    end
  end

  def fetch_replies(actor, opts \\ [fetch_collection: :async])

  def fetch_replies(%{data: %{"replies" => replies}}, opts) do
    fetch_replies(%{"replies" => replies}, opts)
  end

  def fetch_replies(%{"replies" => replies}, opts) do
    Transformer.fix_replies(%{"replies" => replies |> debug()}, opts)
  end

  def fetch_replies(other, opts) do
    with {:ok, %{data: %{"replies" => replies}}} <- Object.get_cached(other) do
      fetch_replies(%{"replies" => replies}, opts)
    else
      e ->
        error(e, "Could not find replies in ActivityPub data")
    end
  end

  @doc """
  Fetches an AS2 object from remote AP ID.
  """
  def fetch_remote_object_from_id(id, options \\ []) do
    debug(id, "Attempting to fetch ActivityPub object")
    # debug(self())

    with true <- Config.federating?() != false || {:error, "Federation is disabled"},
         true <-
           allowed_recursion?(options[:depth]) || {:error, "Stopping to avoid too much recursion"},
         true <-
           String.starts_with?(id, "http") || {:error, "Unsupported URL (should start with http)"},
         uri <- URI.parse(id),
         true <- Instances.reachable?(uri) || {:error, "Instance was recently not reachable"},
         # If we have instance restrictions, apply them here to prevent fetching from unwanted instances
         {:ok, nil} <- ActivityPub.MRF.SimplePolicy.check_reject(uri),
         true <-
           not String.starts_with?(id, ActivityPub.Web.base_url()) || {:error, :local_actor},
         headers <-
           [{"Accept", "application/activity+json"}]
           |> Keys.maybe_add_fetch_signature_headers(uri),
         {:ok, %{body: body, status: code, headers: headers}} when code in 200..299 <-
           HTTP.get(
             id,
             headers
           ),
         _ <- Instances.set_reachable(uri) do
      with {:ok, data} <- Jason.decode(body),
           {:ok, _} <-
             {options[:skip_contain_origin_check] ||
                Containment.contain_origin(Utils.ap_id(data) || id, data), data} do
        if !options[:return_tombstones] and Object.is_deleted?(data) do
          debug("object was marked as deleted/suspended, return as not found")
          {:error, :not_found}
        else
          {:ok, data}
        end
      else
        returned -> handle_fetch_error(returned, id, options, code, headers)
      end
    else
      returned -> handle_fetch_error(returned, id, options)
    end
  end

  defp handle_fetch_error(returned, id, options, status \\ nil, headers \\ nil) do
    case returned do
      {:ok, %{status: 401} = ret} ->
        debug(id, "Received a 401 - authentication required response")
        {:error, maybe_error_body(ret) || :needs_login}

      {:ok, %{status: 304}} ->
        debug(
          "HTTP I am a teapot - we use this for unavailable mocks in tests - return cached object if any or the original ID or object"
        )

        case Object.get_cached(ap_id: id) do
          {:ok, object} -> {:ok, object}
          _ -> {:ok, id}
        end

      {:ok, %{status: code, body: body}}
      when code in [404, 410] and is_binary(body) and body != "" ->
        with true <- options[:return_tombstones],
             {:ok, data} <- Jason.decode(body) do
          warn(
            data,
            "Not found - ActivityPub remote replied with #{code} and an object (maybe a Tombstone)"
          )

          case data do
            %{"suspended" => true} -> {:ok, data}
            %{"type" => "Tombstone"} -> {:ok, data}
            %{"type" => "Delete"} -> {:ok, data}
            %{"object" => %{"type" => "Tombstone"} = actor} -> {:ok, actor}
            _ -> {:error, :not_found}
          end
        else
          e ->
            warn(
              e,
              "Not found - ActivityPub remote replied with #{code}, and could not process object"
            )

            {:error, :not_found}
        end

      {:ok, %{status: code}} when code in [404, 410] ->
        warn(id, "Not found - ActivityPub remote replied with #{code}")
        {:error, :not_found}

      {:error, %Jason.DecodeError{data: data}} ->
        with true <- is_list(headers),
             linked_object_id when is_binary(linked_object_id) <-
               Enum.find_value(headers, fn
                 {"link", link} -> maybe_parse_header_url(link, "application/activity+json")
                 _ -> false
               end) do
          info(headers, "fetch activity+json link found in headers")
          fetch_remote_object_from_id(linked_object_id, options)
        else
          e ->
            error(e, "Could not fallback to finding the object in headers")

            with {:ok, doc} <- Floki.parse_document(data),
                 link <- Floki.find(doc, "link[type='application/activity+json']"),
                 [linked_object_id] when linked_object_id != id <- Floki.attribute(link, "href") do
              info(link, "fetch activity+json link found in html")
              fetch_remote_object_from_id(linked_object_id, options)
            else
              e ->
                error(e, "Could not fallback to finding the object in (headers nor) HTML")

                if options[:return_html] do
                  {:html, data}
                else
                  error(data, "Invalid ActivityPub JSON")
                end
            end
        end

      {:error, :econnrefused} ->
        Instances.set_unreachable(id)
        error("Could not connect to ActivityPub remote")

      {:error, :local_actor} ->
        warn("seems we're trying to fetch a local actor, looking it up from the adapter...")
        Adapter.get_actor_by_ap_id(id)

      {{:error, e}, data} ->
        error(data, e)

      {:error, e} ->
        error(e)

      {:ok, %{status: code} = ret} ->
        error(ret, maybe_error_body(ret) || "ActivityPub remote replied with HTTP #{code}")

      {:reject, e} ->
        {:reject, e}

      e ->
        error(e, "Error trying to connect with ActivityPub remote")
    end
  end

  def maybe_parse_header_url(str, type) do
    case String.split(str, ">", parts: 2) do
      [url_part, rest] ->
        if String.contains?(rest, type), do: String.trim_leading(url_part, "<")

      _ ->
        nil
    end
  end

  defp maybe_error_body(%{body: body, status: code}) when is_binary(body) and body != "" do
    prefix = "Remote response with HTTP #{code}:"

    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => e}}} ->
        "#{prefix} #{e}"

      {:ok, %{"error" => e}} ->
        "#{prefix} #{e}"

      {:ok, %{"message" => e}} ->
        "#{prefix} #{e}"

      _ ->
        nil
    end
  end

  defp maybe_error_body(_), do: nil

  # defp check_if_public(public) when public == true, do: :ok
  # discard for now, to avoid privacy leaks
  # defp check_if_public(_public), do: {:error, "Not public"}

  @spec fetch_collection(String.t() | map()) :: {:ok, [Object.t()]} | {:error, any()}
  def fetch_collection(ap_id, opts \\ [])

  def fetch_collection(ap_id, opts) when is_binary(ap_id) do
    case opts[:mode] do
      mode when mode in [:entries_async, true] ->
        warn(
          mode,
          "fetching collection synchronously (blocking operation) and then queing entries to be fetched async"
        )

        with {:ok, page} <-
               get_cached_object_or_fetch_ap_id(ap_id, skip_contain_origin_check: :ok)
               |> debug("collection fetched") do
          {:ok, handle_collection(page, opts)}
        else
          e ->
            error(e, "Could not fetch collection #{ap_id}")
        end

      :async ->
        debug("queue collection to be fetched async")

        {:ok,
         maybe_fetch(
           ap_id,
           opts
           |> Keyword.put_new(:fetch_collection_entries, :async)
           # |> Keyword.put_new(:skip_cache, true)
         )}

      #  FIXME

      _ ->
        debug("skip")
        {:ok, []}
    end
  end

  def fetch_collection(%{"type" => type} = page, opts)
      when type in ["Collection", "OrderedCollection", "CollectionPage", "OrderedCollectionPage"] do
    {:ok, handle_collection(page, opts)}
  end

  def fetch_collection(%{data: %{"type" => type} = page}, opts)
      when type in ["Collection", "OrderedCollection", "CollectionPage", "OrderedCollectionPage"] do
    {:ok, handle_collection(page, opts)}
  end

  def fetch_collection(other, opts) do
    with {:ok, %{data: %{"id" => collection_ap_id}}} when is_binary(collection_ap_id) <-
           Object.get_cached(other) do
      fetch_collection(collection_ap_id, opts)
    end
  end

  defp handle_collection(page, opts) do
    with entries when is_list(entries) <- objects_from_collection(page, opts) do
      entries
      |> debug("objects_from_collection")
      |> Enum.reject(fn
        # TODO: configurable
        %{"type" => type} when type in ["Announce", "Like"] -> true
        _ -> false
      end)
      |> debug("filtered objects_from_collection")

      case opts[:mode] do
        mode when mode in [:entries_async, :async] and entries != [] ->
          debug("queue objects to be fetched async")

          maybe_fetch(entries, opts) || entries

        true when entries != [] ->
          debug("fetch objects as well")

          fetch_objects_from_id(entries, opts)

        _ when entries == [] ->
          debug("no entries to fetch")
          []

        other ->
          debug(other, "do not fetch collection entries")
          entries
      end
    else
      other ->
        error(other, "no valid collection")
        []
    end
  end

  defp fetch_page(page_id, items \\ [], _opts \\ []) do
    max = Config.get([:activity_pub, :max_collection_objects], 10)

    if Enum.count(items) >= max do
      info(
        max,
        "stop fetching pages, because we have more than the :max_collection_objects setting"
      )

      items
    else
      with {:ok, page} <-
             get_cached_object_or_fetch_ap_id(page_id, skip_contain_origin_check: :ok) do
        objects = items_in_page(page)

        if Enum.count(objects) > 0 do
          maybe_next_page(page, items ++ objects)
        else
          items
        end
      else
        {:error, :not_found} ->
          items

        {:error, error} ->
          error(error, "Could not fetch page #{page_id}")
      end
    end
  end

  defp items_in_page(%{"type" => type, "orderedItems" => items})
       when is_list(items) and type in ["OrderedCollection", "OrderedCollectionPage"],
       do: items

  defp items_in_page(%{"type" => type, "items" => items})
       when is_list(items) and type in ["Collection", "CollectionPage"],
       do: items

  defp objects_from_collection(page, opts \\ [])

  defp objects_from_collection(%{"type" => type, "orderedItems" => items} = page, _opts)
       when is_list(items) and items != [] and
              type in ["OrderedCollection", "OrderedCollectionPage"],
       do: maybe_next_page(page, items)

  defp objects_from_collection(%{"type" => type, "items" => items} = page, _opts)
       when is_list(items) and items != [] and type in ["Collection", "CollectionPage"],
       do: maybe_next_page(page, items)

  defp objects_from_collection(%{"type" => type, "first" => first}, opts)
       when is_binary(first) and type in ["Collection", "OrderedCollection"] do
    fetch_page(first, [], opts)
  end

  defp objects_from_collection(%{"type" => type, "first" => %{"id" => id}}, opts)
       when is_binary(id) and type in ["Collection", "OrderedCollection"] do
    fetch_page(id, [], opts)
  end

  defp objects_from_collection(page, _opts) do
    warn(page, "could not find objects in collection")
    []
  end

  defp maybe_next_page(%{"next" => page_id}, items, opts) when is_binary(page_id) do
    depth = opts[:page_depth] || 0
    #  max pages to fetch
    if allowed_recursion?(depth, opts[:max_pages] || 2) do
      info(depth, "fetch an extra page from collection")
      fetch_page(page_id, items, opts |> Keyword.put(:page_depth, depth + 1))
    else
      items
    end
  end

  defp maybe_next_page(_, items), do: items

  @doc """
  Returns `true` if the distance to target object does not exceed max configured value.
  Serves to prevent fetching of very long threads, especially useful on smaller instances.
  Addresses memory leaks on recursive replies fetching.
  Applies to fetching of both ancestor (reply-to) and child (reply) objects.
  """
  def allowed_recursion?(distance, max_recursion \\ nil) do
    max_distance = max_recursion || max_recursion()

    debug(max_distance, "max_distance")

    if is_number(distance) and is_number(max_distance) and max_distance >= 0 do
      # Default depth is 0 (an object has zero distance from itself in its thread)
      (distance || 0) <= max_distance
    else
      true
    end
  end

  defp max_recursion, do: Config.get([:instance, :federation_incoming_max_recursion]) || 10
end
