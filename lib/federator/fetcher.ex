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

      {:error, :remote_error} ->
        warn("Fetch was attempted recently and resulted in an error, skip and return :not_found")
        {:error, :not_found}

      _ ->
        fetch_remote_object_from_id(id, opts)
    end
  end

  defp get_cached_object_or_maybe_fetch_ap_id(id, opts \\ []) do
    case Object.get_cached(ap_id: id) do
      {:ok, object} ->
        {:ok, object}

      {:error, :remote_error} ->
        warn("Fetch was attempted recently and resulted in an error, skip and return :not_found")
        {:error, :not_found}

      _ ->
        case opts[:mode] do
          false ->
            debug("skip because of mode: false")
            nil

          mode when mode in [:async, nil] ->
            enqueue_fetch(
              id,
              Enum.into(opts[:worker_attrs] || %{}, %{
                "depth" => opts[:depth],
                "fetch_collection_entries" => opts[:fetch_collection_entries],
                "user_id" => opts[:user_id],
                "context" => opts[:triggered_by] || "get_cached_object_or_maybe_fetch_ap_id"
              })
            )

          true ->
            fetch_remote_object_from_id(id, opts)

          other ->
            debug(other, "skip because of mode")
            nil
        end
    end
  end

  @doc """
  Checks if an object exists in the AP database and prepares it if not (local objects only).
  """
  def get_cached_object_or_fetch_pointer_id(pointer, opts \\ []) do
    Object.get_cached(pointer: pointer)
    |> maybe_handle_incoming(
      pointer,
      opts |> Keyword.put_new(:triggered_by, "get_cached_object_or_fetch_pointer_id")
    )
  end

  @doc """
  Checks if an object exists in the AP and Adapter databases and fetches and creates it if not.
  """
  def fetch_object_from_id(id, opts \\ []) do
    opts = opts |> Keyword.put_new(:triggered_by, "fetch_object_from_id")

    case cached_or_handle_incoming(id, opts) do
      {:ok, object} ->
        {:ok, object}

      {:error, :remote_error} ->
        warn("Fetch was attempted recently and resulted in an error, skip and return :not_found")
        {:error, :not_found}

      {:reject, e} ->
        error(:reject, e)
        {:reject, e}

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

  @doc "Fetch a list of objects within recursion limits. Used for reply_to/context, and replies or similar collections."
  def maybe_fetch(entries, opts \\ [])
  def maybe_fetch([], _opts), do: nil

  def maybe_fetch(entries, opts) when is_list(entries) do
    depth = (opts[:depth] || 0) + 1

    if allowed_recursion?(depth) do
      max_items = Config.get([:instance, :federation_incoming_max_items]) || 5

      case opts[:mode] do
        false ->
          debug("skip because of mode: false")
          nil

        mode when mode in [:async, nil] ->
          for {id, index} <- Enum.with_index(entries) do
            entry_depth = depth + index

            if allowed_recursion?(entry_depth, max_items) do
              info(id, "fetch recursed (async)")

              enqueue_fetch(
                id,
                Enum.into(opts[:worker_attrs] || %{}, %{
                  "depth" => entry_depth,
                  "max_depth" => max_items,
                  "fetch_collection_entries" => opts[:fetch_collection_entries],
                  #  just to keep track of who made the request
                  "user_id" => opts[:user_id],
                  "context" => opts[:triggered_by] || "maybe_fetch"
                })
              )
            end
          end

        true ->
          for {id, index} <- Enum.with_index(entries) do
            entry_depth = depth + index

            if allowed_recursion?(entry_depth, max_items) do
              info(id, "fetch recursed (inline)")

              fetch_object_from_id(id,
                depth: entry_depth,
                user_id: opts[:user_id]
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

  def fetch_fresh_object_from_id(id, opts) when is_binary(id) do
    opts = opts |> Keyword.put_new(:triggered_by, "fetch_fresh_object_from_id")
    base_url = ActivityPub.Web.base_url()

    with true <- String.starts_with?(id, "http"),
         false <- String.starts_with?(id, base_url),
         {:ok, data} <- fetch_remote_object_from_id(id, opts) |> debug("fetched"),
         {:ok, object} <-
           cached_or_handle_incoming(data, Keyword.put(opts, :already_fetched, true)) do
      {:ok, object}
    else
      true ->
        maybe_get_local(id)

      {:reject, e} ->
        error(:reject, e)
        {:reject, e}

      {:error, e} ->
        {:error, e}

      other ->
        error(other)
    end
  end

  defp maybe_get_local(id) when is_binary(id) do
    warn(id, "seems we're trying to fetch a local object...")

    with {:error, :not_found} <- Object.get_cached(ap_id: id) do
      warn(id, "could not find in cache or AP db, looking it up from the adapter...")
      Adapter.get_actor_by_ap_id(id)
    end
  end

  def cached_or_handle_incoming(id_or_data, opts \\ [])

  def cached_or_handle_incoming(%{"type" => type} = id_or_data, opts)
      when ActivityPub.Config.is_in(type, :supported_actor_types) do
    debug("create/update an Actor")
    |> debug("opts")

    handle_fetched(
      id_or_data,
      opts |> Keyword.put_new(:triggered_by, "cached_or_handle_incoming")
    )
  end

  def cached_or_handle_incoming(id_or_data, opts)
      when is_binary(id_or_data) or
             (is_map(id_or_data) and
                (is_map_key(id_or_data, :ap_id) or is_map_key(id_or_data, "id"))) do
    Object.get_cached(ap_id: id_or_data)
    |> debug("got from cache")
    |> maybe_handle_incoming(
      id_or_data,
      opts |> Keyword.put_new(:triggered_by, "cached_or_handle_incoming")
    )
  end

  def cached_or_handle_incoming(%ActivityPub.Object{} = object, opts) do
    # TODO: clean up workaround
    maybe_handle_incoming(
      {:ok, object},
      object,
      opts |> Keyword.put_new(:triggered_by, "cached_or_handle_incoming")
    )
  end

  def cached_or_handle_incoming(%{status: _, body: _} = data, _opts) do
    # returning the raw HTML
    {:ok, data}
  end

  def cached_or_handle_incoming(id_or_data, _opts) do
    err(id_or_data, "Unexpected AP data")
  end

  defp maybe_handle_incoming(cached, id_or_data, opts) do
    opts = opts |> Keyword.put_new(:triggered_by, "maybe_handle_incoming")

    case cached do
      # {:ok, %{local: true}} ->
      #   debug("local object so don't treat as incoming")
      #   {:ok, cached}

      {:ok, %{pointer_id: nil, data: data} = _object} ->
        warn(
          "seems the object was already cached in object table, but not processed/saved by the adapter"
        )

        handle_fetched(data, opts)
        |> debug("re-handled")

      {:ok, %Object{data: %{"type" => type}} = object}
      when ActivityPub.Config.is_in(type, :supported_actor_types) ->
        debug("Object is an actor, so should be formatted")
        {:ok, Actor.format_remote_actor(object)}

      {:ok, %Object{data: %{"replies" => _replies} = data}} ->
        if opts[:fetch_collection_entries] || opts[:fetch_collection] do
          debug("object is ready as-is, let's maybe fetch replies though...")

          fetch_replies(data, opts)
        else
          debug("object is ready as-is, and not fetching replies")
        end

        cached

      {:ok, _} ->
        debug("object is ready as-is")

        cached

      {:error, :not_found} when is_map(id_or_data) ->
        case id_or_data do
          %{local: true} ->
            debug("local object so don't treat as incoming")
            {:ok, id_or_data}

          _ ->
            debug(id_or_data, "seems like a new-to-us remote object")

            handle_fetched(id_or_data, opts)
            |> debug("handled")
        end

      {:error, :not_found} ->
        warn(id_or_data, "No such object has been cached")
        {:error, :not_found}

      other ->
        error(other)
    end
  end

  defp handle_fetched(%{data: data}, opts), do: handle_fetched(data, opts)

  defp handle_fetched(data, opts) do
    debug(data, "data")

    opts =
      opts
      |> Keyword.put_new(:triggered_by, "handle_fetched")
      |> debug("opts")

    with {:ok, object} <- Transformer.handle_incoming(data, opts) |> debug("handled") do
      #  :ok <- check_if_public(object.public) do # huh?
      fetch_collection_mode = opts[:fetch_collection]
      skip_fetch_collection? = !fetch_collection_mode
      fetch_collection_entries = opts[:fetch_collection_entries]
      # skip_fetch_collection_entries? = !fetch_collection_entries

      case object do
        %Actor{data: %{"outbox" => outbox}}
        when is_binary(outbox) and skip_fetch_collection? == false ->
          debug(
            outbox,
            "An actor was fetched, fetch outbox collection (and maybe queue a fetch of entries as well)"
          )

          maybe_fetch_collection(outbox,
            mode: fetch_collection_mode,
            triggered_by: opts[:triggered_by]
          )

          {:ok, object}

        # %{data: %{"type" => type} = collection}
        # when ActivityPub.Config.is_in(type, :collection_types)
        # and skip_fetch_collection_entries? == false ->
        #   debug(
        #     fetch_collection_entries,
        #     "A collection was fetched, queue a fetch of entries as well"
        #   )

        #   handle_collection(collection,
        #     mode: fetch_collection_entries,
        #     triggered_by: opts[:triggered_by]
        #   )

        #   {:ok, object}

        %{"type" => type} = collection
        when ActivityPub.Config.is_in(type, :collection_types) and
               fetch_collection_entries != false ->
          debug(
            fetch_collection_entries,
            "A collection was fetched, queue a fetch of entries as well"
          )

          handle_collection(
            collection,
            opts
            |> Keyword.put(:mode, fetch_collection_entries)
          )

          {:ok, object}

        # return the object rather than a Create activity (do we want this?)
        %{
          data: %{"type" => "Create"},
          object: %{id: _} = object,
          pointer_id: created_pointer_id,
          pointer: created_pointer
        } = _activity ->
          {:ok,
           object
           |> Utils.maybe_put(:pointer_id, created_pointer_id || Utils.uid(created_pointer))
           |> Utils.maybe_put(:pointer, created_pointer)}

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

    fetch_collection(outbox,
      mode: opts[:fetch_collection],
      triggered_by: opts[:triggered_by] || "fetch_outbox"
    )
  end

  def fetch_outbox(other, opts) do
    with {:ok, %{data: %{"outbox" => outbox}}} when is_binary(outbox) <-
           Actor.get_cached(other) do
      fetch_outbox(%{"outbox" => outbox}, opts)
    end
  end

  def fetch_thread(actor, opts \\ [fetch_collection: :async])

  def fetch_thread(%{data: data}, opts) do
    fetch_thread(data, opts)
  end

  def fetch_thread(%{"id" => _} = data, opts) do
    data
    |> Transformer.fix_replies(opts)
    |> Transformer.fix_in_reply_to(opts)
    |> Transformer.fix_context(opts)

    # |> debug()
  end

  def fetch_thread(other, opts) do
    with {:ok, %{data: data}} <- Object.get_cached(other) |> debug("got_object") do
      fetch_thread(data, opts)
    else
      {:error, :not_found} ->
        error(other, "Could not find replies in ActivityPub data")

      e ->
        error(e, "Could not find replies in ActivityPub data")
    end
  end

  def fetch_replies(actor, opts \\ [fetch_collection: :async])

  def fetch_replies(%{data: %{"replies" => replies}}, opts) do
    fetch_replies(%{"replies" => replies}, opts)
  end

  def fetch_replies(%{"replies" => replies}, opts) do
    Transformer.fix_replies(%{"replies" => replies |> debug("fetching replies")}, opts)
    # |> debug()
  end

  def fetch_replies(%{"id" => _} = data, _opts) do
    error(data, "Could not find replies in ActivityPub data")
  end

  def fetch_replies(other, opts) do
    with {:ok, %{data: %{"replies" => replies} = _data}} <-
           Object.get_cached(other) |> debug("got_object") do
      fetch_replies(%{"replies" => replies}, opts)
    else
      {:error, :not_found} ->
        error(other, "Could not find replies in ActivityPub data")

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
           allowed_recursion?(options[:depth], options[:max_depth]) ||
             {:error, "Stopping to avoid too much recursion"},
         true <-
           String.starts_with?(id, "http") || {:error, "Unsupported URL (should start with http)"},
         uri <- URI.parse(id),
         true <-
           options[:force_instance_reachable] || Instances.reachable?(uri) ||
             {:error, "Instance was recently not reachable"},
         # If we have instance restrictions, apply them here to prevent fetching from unwanted instances
         {:ok, nil} <- ActivityPub.MRF.SimplePolicy.check_reject(uri),
         true <-
           not String.starts_with?(id, ActivityPub.Web.base_url()) || {:error, :is_local},
         headers <-
           [{"Accept", "application/activity+json"}]
           |> Keys.maybe_add_fetch_signature_headers(uri)
           |> debug("ready to fetch #{inspect(id)} with signature headers"),
         {:ok, %{body: body, status: code, headers: headers}} when code in 200..299 <-
           HTTP.get(
             id,
             headers
           )
           |> debug("fetch_done"),
         _ <- Instances.set_reachable(uri) do
      with {:ok, data} <- Jason.decode(body),
           {true, _} <-
             {options[:skip_contain_origin_check] ||
                Containment.contain_origin(Utils.ap_id(data) || id, data) ||
                {:error, "Containment error"}, data} do
        if !options[:return_tombstones] and Object.is_deleted?(data) do
          debug(options, "object was marked as deleted/suspended, return as not found")
          cache_fetch_error(id)
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
            %{"suspended" => true} ->
              {:ok, data}

            %{"type" => "Tombstone"} ->
              {:ok, data}

            %{"type" => "Delete"} ->
              {:ok, data}

            %{"object" => %{"type" => "Tombstone"} = actor} ->
              {:ok, actor}

            _ ->
              cache_fetch_error(id)
              {:error, :not_found}
          end
        else
          e ->
            warn(
              e,
              "Not found - ActivityPub remote replied with #{code}, and did not request `return_tombstones` or could not process body"
            )

            cache_fetch_error(id)
            {:error, :not_found}
        end

      {:ok, %{status: code}} when code in [404, 410] ->
        warn(id, "Not found - ActivityPub remote replied with #{code}")
        cache_fetch_error(id)
        {:error, :not_found}

      {:error, %Jason.DecodeError{data: data} = json_error} ->
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
                cache_fetch_error(id)
                error(e, "Could not fallback to finding the object in (headers nor) HTML")

                if options[:return_html_as_fallback] do
                  {:ok, %{status: status || 200, body: data}}
                else
                  error(json_error, "Invalid ActivityPub JSON")
                end
            end
        end

      {:error, :econnrefused} ->
        # cache_fetch_error(id)
        Instances.set_unreachable(id)
        error("Could not connect to ActivityPub remote")
        {:error, :network_error}

      {:error, :is_local} ->
        with {:ok, actor} <- maybe_get_local(id) do
          {:ok, actor}
        else
          {:error, :not_found} ->
            {:error, :is_local}

          e ->
            error(
              e,
              "the caller attempted to fetch a local object (which doesn't seem to be a local actor)"
            )
        end

      {{:error, e}, data} ->
        # cache_fetch_error(id)
        error(data, e)

      {:error, e} ->
        # cache_fetch_error(id)
        error(e)

      {:ok, %{status: code} = ret} ->
        cache_fetch_error(id)
        error(ret, "ActivityPub remote replied with unexpected HTTP code")
        {:error, maybe_error_body(ret) || :network_error}

      {:reject, e} ->
        {:reject, e}

      e ->
        # cache_fetch_error(id)
        error(e, "Error trying to connect with ActivityPub remote")
    end
  end

  def cache_fetch_error(id) do
    Cachex.put(:ap_actor_cache, id, {:error, :remote_error})
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

  def maybe_fetch_collection(ap_id, opts) do
    fetch_collection(
      ap_id,
      opts
      |> Keyword.put_new(:mode, false)
    )
  end

  @spec fetch_collection(String.t() | map()) :: {:ok, [Object.t()]} | {:error, any()}
  def fetch_collection(ap_id, opts \\ [])

  def fetch_collection(ap_id, opts) when is_binary(ap_id) do
    opts =
      opts
      |> Keyword.put_new(:triggered_by, "fetch_collection")
      |> debug("opts")

    case opts[:mode] do
      false ->
        debug("skip")
        {:ok, []}

      :async ->
        debug("queue collection to be fetched async")

        {:ok,
         maybe_fetch(
           ap_id,
           opts
           |> Keyword.put_new(:fetch_collection_entries, :async)
           # |> Keyword.put_new(:skip_cache, true)
         )}

      entries_async_mode ->
        warn(
          entries_async_mode,
          "fetching collection synchronously (blocking operation) and then queuing entries to be fetched async"
        )

        with {:ok, page} <-
               get_cached_object_or_fetch_ap_id(ap_id, skip_contain_origin_check: true)
               |> debug("collection fetched") do
          {:ok, handle_collection(page, opts)}
        else
          e ->
            err(e, "Could not fetch collection #{ap_id}")
        end
    end
  end

  def fetch_collection(%{"type" => type} = page, opts)
      when type in ["Collection", "OrderedCollection", "CollectionPage", "OrderedCollectionPage"] do
    {:ok, handle_collection(page, opts |> Keyword.put_new(:triggered_by, "fetch_collection"))}
  end

  def fetch_collection(%{data: %{"type" => type} = page}, opts)
      when type in ["Collection", "OrderedCollection", "CollectionPage", "OrderedCollectionPage"] do
    {:ok, handle_collection(page, opts |> Keyword.put_new(:triggered_by, "fetch_collection"))}
  end

  def fetch_collection(other, opts) do
    with {:ok, %{data: %{"id" => collection_ap_id}}} when is_binary(collection_ap_id) <-
           Object.get_cached(other) do
      fetch_collection(
        collection_ap_id,
        opts |> Keyword.put_new(:triggered_by, "fetch_collection")
      )
    end
  end

  defp handle_collection(page, opts) do
    opts = opts |> Keyword.put_new(:triggered_by, "handle_collection")

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

  defp fetch_page(page_id, items \\ [], opts \\ []) do
    max = Config.get([:activity_pub, :max_collection_objects], 10)

    if Enum.count(items) >= max do
      info(
        max,
        "stop fetching pages, because we have more than the :max_collection_objects setting"
      )

      items
    else
      with {:ok, page} <-
             get_cached_object_or_maybe_fetch_ap_id(
               page_id,
               opts
               |> Keyword.put_new(:skip_contain_origin_check, true)
               |> Keyword.put_new(:triggered_by, "fetch_page")
             ) do
        objects = items_in_page(page)

        if Enum.count(objects) > 0 do
          maybe_next_page(
            page,
            items ++ objects,
            opts
            |> Keyword.put_new(:triggered_by, "fetch_page")
          )
        else
          items
        end
      else
        {:error, :not_found} ->
          items

        nil ->
          items

        {:error, error} ->
          error(error, "Could not fetch page #{page_id}")
      end
    end
  end

  defp items_in_page(%{"orderedItems" => items})
       when is_list(items),
       do: items

  defp items_in_page(%{"items" => items})
       when is_list(items),
       do: items

  defp items_in_page(other) do
    warn(other, "unrecognised, maybe fetching async")
    []
  end

  defp objects_from_collection(page, opts \\ [])

  defp objects_from_collection(%{"type" => type, "orderedItems" => items} = page, opts)
       when is_list(items) and items != [] and
              type in ["OrderedCollection", "OrderedCollectionPage"],
       do:
         maybe_next_page(
           page,
           items,
           opts
           |> Keyword.put_new(:triggered_by, "objects_from_collection")
         )

  defp objects_from_collection(%{"type" => type, "items" => items} = page, opts)
       when is_list(items) and items != [] and type in ["Collection", "CollectionPage"],
       do:
         maybe_next_page(
           page,
           items,
           opts
           |> Keyword.put_new(:triggered_by, "objects_from_collection")
         )

  defp objects_from_collection(%{"type" => type, "first" => first}, opts)
       when is_binary(first) and type in ["Collection", "OrderedCollection"] do
    fetch_page(
      first,
      [],
      opts
      |> Keyword.put_new(:triggered_by, "objects_from_collection")
    )
  end

  defp objects_from_collection(%{"type" => type, "first" => %{"id" => id}}, opts)
       when is_binary(id) and type in ["Collection", "OrderedCollection"] do
    fetch_page(
      id,
      [],
      opts
      |> Keyword.put_new(:triggered_by, "objects_from_collection")
    )
  end

  defp objects_from_collection(%{"type" => type, "next" => next}, opts)
       when is_binary(next) and type in ["CollectionPage"] do
    # needed for GtS
    fetch_page(
      next,
      [],
      opts
      |> Keyword.put_new(:triggered_by, "objects_from_collection")
    )
  end

  defp objects_from_collection(page, _opts) do
    warn(page, "could not find objects in collection")
    []
  end

  defp maybe_next_page(page, items, opts \\ [])

  defp maybe_next_page(%{"next" => page_id}, items, opts) when is_binary(page_id) do
    depth = opts[:page_depth] || 0
    #  max pages to fetch
    if allowed_recursion?(depth, opts[:max_pages] || 2) do
      info(depth, "fetch an extra page from collection")

      fetch_page(
        page_id,
        items,
        opts
        |> Keyword.put(:page_depth, depth + 1)
        |> Keyword.put_new(:triggered_by, "maybe_next_page")
      )
    else
      items
    end
  end

  defp maybe_next_page(_, items, _), do: items

  @doc """
  Returns `true` if the distance to target object does not exceed max configured value.
  Serves to prevent fetching of very long threads, especially useful on smaller instances.
  Addresses memory leaks on recursive replies fetching.
  Applies to fetching of both ancestor (reply-to) and child (reply) objects.
  """
  def allowed_recursion?(distance, max_recursion \\ nil) do
    max_distance = max_recursion || max_recursion()

    debug(distance, "distance")
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
