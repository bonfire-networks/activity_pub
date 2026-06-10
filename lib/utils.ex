defmodule ActivityPub.Utils do
  @moduledoc """
  Misc functions used for federation
  """
  alias ActivityPub.Config
  import ActivityPub.Config
  # alias ActivityPub.Actor
  # alias ActivityPub.Object
  alias ActivityPub.Federator.Adapter
  alias Ecto.UUID
  import Untangle
  # import Ecto.Query

  def repo, do: ProcessTree.get(:ecto_repo_module) || ActivityPub.Config.get!(:repo)

  def adapter_fallback() do
    warn("Could not find an ActivityPub adapter, falling back to TestAdapter")

    ActivityPub.TestAdapter
  end

  def make_date do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  # def generate_context_id, do: generate_id("contexts")

  def generate_object_id(generator \\ &UUID.generate/0), do: generate_id("objects", generator)

  def generate_id(type, generator \\ &UUID.generate/0),
    do: ap_base_url() <> "/#{type}/#{generator.()}"

  def ap_base_url() do
    ActivityPub.Web.base_url() <> System.get_env("AP_BASE_PATH", "/pub")
  end

  @doc "Returns host:port for non-standard ports, bare host otherwise."
  def authority(%{host: host, port: port, scheme: scheme}) when is_binary(host) do
    cond do
      is_nil(port) -> host
      scheme == "https" and port == 443 -> host
      scheme == "http" and port == 80 -> host
      true -> "#{host}:#{port}"
    end
  end

  def authority(%{host: host}) when is_binary(host), do: host

  def authority(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.host do
      authority(uri)
    else
      # URI.parse("localhost:4002") gives %URI{scheme: "localhost", path: "4002", host: nil}
      # so treat it as a bare authority string and return as-is
      url
    end
  end

  @doc "Builds a base URL (scheme://host[:port]) from a URI, omitting standard ports."
  def base_url(%{scheme: scheme, host: host} = uri) when is_binary(scheme) and is_binary(host),
    do: scheme <> "://" <> authority(uri)

  def base_url(%{host: host} = uri) when is_binary(host), do: "http://" <> authority(uri)

  def base_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.host do
      base_url(uri)
    else
      # Bare authority like "localhost:4002" — infer scheme
      scheme = if String.starts_with?(url, "localhost"), do: "http", else: "https"
      "#{scheme}://#{url}"
    end
  end

  def activitypub_object_headers, do: [{"content-type", "application/activity+json"}]

  @collections_segment "/collections/"

  @doc """
  The stable, dereferenceable id for a collection: `{base}/collections/{type}/{uuid}`. A neutral URL
  helper — used for both store-backed (e.g. keyPackages) and adapter/extension-owned (e.g. featured)
  collections. `type` lets serving dispatch by pure path-parse; `uuid` identifies *which* collection
  (the owner actor's id for singleton-per-actor collections, or the collection's own id otherwise).
  """
  def collection_ap_id(type, uuid) when is_binary(type) and is_binary(uuid),
    do: "#{ap_base_url()}#{@collections_segment}#{type}/#{uuid}"

  @doc "Inverse of `collection_ap_id/2`: parse a collection id into `{:ok, type, uuid}`, or `:error`."
  def parse_collection_ap_id(ap_id) when is_binary(ap_id) do
    with [_base, rest] <- String.split(ap_id, @collections_segment, parts: 2),
         [type, uuid] <- String.split(rest, "/", parts: 2),
         true <- type != "" and uuid != "" and not String.contains?(uuid, ["/", "?", "#"]) do
      {:ok, type, uuid}
    else
      _ -> :error
    end
  end

  def parse_collection_ap_id(_), do: :error

  def make_json_ld_header(type \\ :object) do
    %{
      "@context" => make_json_ld_context_list(type)
    }
  end

  def make_json_ld_context_list(type \\ :object)

  def make_json_ld_context_list(:actor = type) do
    [
      "https://www.w3.org/ns/activitystreams",
      "https://w3id.org/security/v1",
      do_make_json_ld_context_list(type)
    ]
  end

  def make_json_ld_context_list(type) do
    [
      "https://www.w3.org/ns/activitystreams",
      do_make_json_ld_context_list(type)
    ]
  end

  defp do_make_json_ld_context_list(type) do
    json_contexts = Application.get_env(:activity_pub, :json_contexts, [])

    Enum.into(
      stringify_keys(json_contexts[type] || json_contexts[:object]) || %{},
      %{
        "@language" => Adapter.get_locale()
      }
    )
  end

  @doc """
  Determines if an object or an activity is public.
  """

  def public?(%{public: true}, %{public: true}), do: true
  def public?(%{public: false}, %{public: _}), do: false
  def public?(%{public: _}, %{public: false}), do: false

  def public?(activity_data, %{data: object_data}) do
    public?(activity_data, object_data)
  end

  def public?(%{data: activity_data}, object_data) do
    public?(activity_data, object_data)
  end

  def public?(%{"to" => to} = activity_data, %{"to" => to2} = object_data)
      when not is_nil(to) and not is_nil(to2) do
    public?(activity_data) && public?(object_data)
  end

  def public?(_, %{"to" => to} = object_data) when not is_nil(to) do
    public?(object_data)
  end

  def public?(%{"to" => to} = activity_data, _) when not is_nil(to) do
    public?(activity_data)
  end

  def public?(activity_data, object_data) do
    public?(activity_data) || public?(object_data)
  end

  def public?(%{public: true}), do: true
  def public?(%{public: false}), do: false
  def public?(%{data: data}), do: public?(data)
  def public?(%{"type" => "Tombstone"}), do: false
  def public?(%{"type" => "Move"}), do: true
  def public?(%{"directMessage" => true}), do: false

  def public?(%{"publishedDate" => _}) do
    # workaround for bookwyrm
    true
  end

  def public?(%{} = params) when is_map(params) or is_list(params) do
    [params["to"], params["cc"], params["bto"], params["bcc"]]
    |> has_as_public?()
  end

  def public?(data) when is_binary(data) do
    has_as_public?(data)
  end

  def public?(_data) do
    false
  end

  def has_as_public?(tos) do
    any_in_collections?(Config.public_uris(), tos)
  end

  @doc """
  Checks if any of the given labels exist in any of the given collections.
  Supports both single values and lists for labels and collections.
  """
  @spec any_in_collections?(any(), any()) :: boolean()
  def any_in_collections?(labels, collection) when is_list(labels) do
    List.flatten(labels)
    |> Enum.any?(&any_in_collections?(&1, collection))
  end

  def any_in_collections?(label, collections) when is_list(collections) do
    List.flatten(collections)
    |> Enum.any?(&any_in_collections?(label, &1))
  end

  # Base cases for direct comparison
  def any_in_collections?(item, item), do: true
  def any_in_collections?(id, %{"id" => id}), do: true
  def any_in_collections?(%{"id" => id}, id), do: true
  def any_in_collections?(%{"id" => id}, %{"id" => id}), do: true

  def any_in_collections?(item, collection) do
    # debug(item, "Item not matched")
    # err(collection, "Collection not matched")
    false
  end

  @doc "Takes a string and returns true if it is a valid UUID (Universally Unique Identifier)"
  def is_uuid?(str) do
    Needle.UID.is_uuid?(str)
  end

  def is_ulid?(str) when is_binary(str) and byte_size(str) == 26 do
    Needle.UID.is_ulid?(str)
  end

  def is_ulid?(_), do: false

  def is_uid?(input) do
    is_ulid?(input) or is_uuid?(input)
  end

  def uid(%{pointer_id: id}) when is_binary(id), do: uid(id)
  def uid(%{id: id}) when is_binary(id), do: uid(id)

  def uid(input) do
    if is_uid?(input) do
      input
    else
      warn(input, "Expected a ULID ID (or an object with one), but got")
      nil
    end
  end

  def ap_id(%{ap_id: id}), do: id
  def ap_id(%{data: %{"id" => id}}), do: id
  def ap_id(%{"id" => id}), do: id
  def ap_id(id) when is_binary(id), do: id

  def ap_id(other) do
    warn(other, "Could not determine ap_id")
    nil
  end

  def ap_id!(id) do
    ap_id(id) ||
      raise("Could not determine ap_id")
  end

  @doc "The ap_id of an activity's wrapped object (`data->'object'`, a map or string), or `nil`."
  def object_ap_id_of(%{data: %{"object" => object}}) when not is_nil(object), do: ap_id(object)
  def object_ap_id_of(_), do: nil

  @doc "Normalise a subject (URI, ap_id string, or actor/object) to a `%URI{}`, or `nil` if undeterminable."
  def ap_uri(%URI{} = uri), do: uri
  def ap_uri(subject) when is_binary(subject), do: URI.parse(subject)
  def ap_uri(nil), do: nil
  def ap_uri(subject), do: subject |> ap_id() |> ap_uri()

  def some_identifier(_, id) when is_binary(id) do
    id
  end

  def some_identifier(:id, %{id: id}) do
    id
  end

  def some_identifier(:pointer_id, %{pointer_id: id}) do
    id
  end

  def some_identifier(:pointer_id, %{pointer: %{id: id}}) do
    id
  end

  def some_identifier(:ap_id, %{"id" => id}) do
    id
  end

  def some_identifier(:ap_id, %{data: %{"id" => id}}) do
    id
  end

  def some_identifier(:ap_id, %{ap_id: id}) do
    id
  end

  # def some_identifier(_, object) do
  #   uid(object) || ap_id(object)
  # end

  @doc """
  Generates a consistent cache key for ActivityPub cache buckets.

  ## Examples

      iex> ActivityPub.Utils.ap_cache_key(:pointer, "01K62V27CP9Z5B0AP231QSY199")
      "abc123:pointer:01K62V27CP9Z5B0AP231QSY199"

  """
  def ap_cache_key(key, id_or_object) do
    do_ap_cache_key(key, some_identifier(key, id_or_object))
  end

  def do_ap_cache_key(key, id) do
    "#{short_hash(repo(), 6)}:#{key}:#{id}"
  end

  # def maybe_forward_activity(
  #       %{data: %{"type" => "Create", "to" => to, "object" => object}} = activity
  #     ) do
  #     to
  #     |> List.delete("https://www.w3.org/ns/activitystreams#Public")
  #     |> Enum.map(&Actor.get_cached_by_ap_id!/1)
  #     |> Enum.filter(fn actor ->
  #       actor.data["type"] == "Group"
  #     end)
  #   |> Enum.map(fn group ->
  #     ActivityPub.create(%{
  #       to: ["https://www.w3.org/ns/activitystreams#Public"],
  #       object: object,
  #       actor: group,
  #       context: activity.data["context"],
  #       additional: %{
  #         "cc" => [group.data["followers"]],
  #         "attributedTo" => activity.data["actor"]
  #       }
  #     })
  #   end)
  # end

  # def maybe_forward_activity(_), do: :ok

  @doc """
  Whether the AP caches are live. They're bypassed by default in the test env (Ecto sandbox / ExUnit
  workaround); a test opts its process in via `Process.put(:activity_pub_enable_cache, true)`.
  """
  def cache_enabled?,
    do: Config.env() != :test or Process.get(:activity_pub_enable_cache) == true

  @doc """
  Classify a `ref` into `{kind, normalised_id}` for cache/query dispatch: `:pointer` (ULID/UID) |
  `:ap_id` (URI) | `:id` (uuid) | `:username`, or `{nil, nil}` if unresolvable. Accepts a binary id
  **or** a struct/map — the matched field tells us the kind directly (no re-classification), like
  `get_cached/1`. Shared by `get_cached/1` and `list_with_cache/4` so they never drift.
  """
  def classify_ref(ref) when is_binary(ref) do
    cond do
      String.starts_with?(ref, "http") -> {:ap_id, ref}
      is_ulid?(ref) -> {:pointer, uid(ref)}
      is_uuid?(ref) -> {:id, ref}
      true -> {:username, ref}
    end
  end

  # struct/map ref — the field we match tells us the kind directly
  def classify_ref(%{pointer_id: id}) when is_binary(id), do: {:pointer, uid(id)}
  def classify_ref(%{ap_id: ap_id}) when is_binary(ap_id), do: {:ap_id, ap_id}
  def classify_ref(%{data: %{"id" => ap_id}}) when is_binary(ap_id), do: {:ap_id, ap_id}
  def classify_ref(%{"id" => ap_id}) when is_binary(ap_id), do: {:ap_id, ap_id}
  def classify_ref(%{username: username}) when is_binary(username), do: {:username, username}
  def classify_ref(%{id: id}) when is_binary(id), do: classify_ref(id)
  def classify_ref(_), do: {nil, nil}

  @doc """
  Batched, cache-aware sibling of `get_with_cache/5`: resolves many `refs` with **one query per
  kind** for the cache misses (no N+1), populating the cache the same way `get_with_cache` does, and
  returning results **in input order** (missing dropped unless `opts[:keep_nil]`).

  `funs` carries the schema specifics; sensible defaults are used for any `ap_object`-backed schema,
  so a caller usually only passes `%{query_module: MySchema}`:
  - `query_module` — its `query/1` accepts `[{:ap_id|:pointer_id|:id|:username, value_or_list}]`
  - `classify.(ref) -> {kind, id}` — default `classify_ref/1`
  - `fetch.(kind, ids) -> [row]` — default: `repo().all(query_module.query([{query_key(kind), ids}]))`
  - `kind_key.(kind, row) -> id` — default keys a row back by its `:ap_id`/`:pointer`/`:id`/`:username`
  - `cache_keys.(row) -> [cache_key]` — default: the `id`/`ap_id`/`pointer` alias keys (mirrors `set_cache`)
  """
  def list_with_cache(refs, bucket, funs, opts \\ []) when is_list(refs) and is_map(funs) do
    enabled? = cache_enabled?()

    classify = funs[:classify] || (&classify_ref/1)
    fetch = funs[:fetch] || default_fetch(funs[:query_module])
    kind_key = funs[:kind_key] || (&default_kind_key/2)
    cache_keys = funs[:cache_keys] || (&default_cache_keys/1)

    # classify each ref (binary id or struct/map); unresolvable refs get `kind: nil` and resolve to
    # `nil` (no cache read, no query) rather than crashing.
    entries =
      Enum.map(refs, fn ref ->
        {kind, id} = classify.(ref)
        %{ref: ref, kind: kind, id: id}
      end)

    # cache pass: in-memory reads only (no DB). Track positive hits and negatively-cached absences.
    # Skipped entirely when caching is off (every ref is a miss → batched query below).
    {cached, absent} =
      if enabled? do
        Enum.reduce(entries, {%{}, MapSet.new()}, fn
          %{kind: nil}, acc ->
            acc

          e, {hits, absent} ->
            case Cachex.get(bucket, ap_cache_key(e.kind, e.id)) do
              {:ok, :not_found} -> {hits, MapSet.put(absent, e.ref)}
              {:ok, row} when is_struct(row) -> {Map.put(hits, e.ref, row), absent}
              _ -> {hits, absent}
            end
        end)
      else
        {%{}, MapSet.new()}
      end

    # miss pass: one batched query per kind → %{kind => %{id => row}}. When caching is off every
    # entry is a miss (nothing to reject). `kind: nil` entries are never queried.
    misses =
      if(enabled?,
        do:
          Enum.reject(entries, fn e ->
            Map.has_key?(cached, e.ref) or MapSet.member?(absent, e.ref)
          end),
        else: entries
      )
      |> Enum.reject(&is_nil(&1.kind))

    fetched_by_kind =
      misses
      |> Enum.group_by(& &1.kind, & &1.id)
      |> Map.new(fn {kind, ids} ->
        rows = fetch.(kind, Enum.uniq(ids))
        {kind, Map.new(rows, &{kind_key.(kind, &1), &1})}
      end)

    if enabled? do
      fetched = Enum.flat_map(fetched_by_kind, fn {_kind, m} -> Map.values(m) end)
      pairs = Enum.flat_map(fetched, fn row -> Enum.map(cache_keys.(row), &{&1, row}) end)
      if pairs != [], do: Cachex.put_many(bucket, pairs)
    end

    results =
      Enum.map(entries, fn e -> cached[e.ref] || get_in(fetched_by_kind, [e.kind, e.id]) end)

    if opts[:keep_nil], do: results, else: Enum.reject(results, &is_nil/1)
  end

  @doc "Run a query expecting at most one row: `{:ok, row}` or `{:error, :not_found}`."
  def one(query) do
    case repo().one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  # default `funs` for an `ap_object`-backed schema (Object/Actor) — overridable per call
  defp default_fetch(query_module) when not is_nil(query_module),
    do: fn kind, ids -> repo().all(query_module.query([{query_key(kind), ids}])) end

  defp query_key(:pointer), do: :pointer_id
  defp query_key(:ap_id), do: :ap_id
  defp query_key(:id), do: :id
  defp query_key(:username), do: :username

  defp default_kind_key(:ap_id, %{data: %{"id" => ap_id}}), do: ap_id
  defp default_kind_key(:pointer, %{pointer_id: pid}), do: pid
  defp default_kind_key(:id, %{id: id}), do: id
  defp default_kind_key(:username, %{data: %{"preferredUsername" => u}}), do: u

  # the alias cache keys for one row (mirrors `set_cache`/`maybe_multi_cache`)
  defp default_cache_keys(%{id: id, data: %{"id" => ap_id}, pointer_id: pid}) do
    base = [ap_cache_key(:id, id), ap_cache_key(:ap_id, ap_id)]
    if pid, do: [ap_cache_key(:pointer, pid) | base], else: base
  end

  def cachex_fetch(cache, key, fallback, options \\ []) when is_function(fallback) do
    if not cache_enabled?() do
      # bypassed in the test env by default (Ecto sandbox / ExUnit workaround); opt in per-process
      # via `Process.put(:activity_pub_enable_cache, true)`.
      fallback.()
    else
      {context, options} = Keyword.pop(options, :multi_tenant_context)
      context = context || Adapter.get_multi_tenant_context()

      Cachex.fetch(
        cache,
        key,
        fn _ ->
          Adapter.set_multi_tenant_context(context)
          fallback.()
        end,
        options
      )
    end
  end

  def cache_clear() do
    Cachex.clear(:ap_actor_cache)
    Cachex.clear(:ap_object_cache)
  end

  # TODO: avoid storing multiple copies of things in cache
  # def get_with_cache(get_fun, cache_bucket, :id, identifier) do
  #   do_get_with_cache(get_fun, cache_bucket, :id, identifier)
  # end
  # def get_with_cache(get_fun, cache_bucket, key, identifier) do
  #   cachex_fetch(cache_bucket, key, fn ->
  #   end)
  # end

  @doc """
  Calculates a TTL (in seconds) for caching based on the published date of an object.
  If the published date is in the future, returns the number of seconds until then (plus a small buffer).
  Otherwise, returns the default TTL (nil).

  ## Examples

      iex> ActivityPub.Utils.cache_ttl_from_published(%{"published" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 10))})
      10..15
      
      iex> ActivityPub.Utils.cache_ttl_from_published(%{"published" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -10))})
      nil
  """
  def cache_ttl_from_published(published) when is_binary(published) do
    with {:ok, dt, _} <- DateTime.from_iso8601(published),
         diff when diff > 0 <- DateTime.diff(dt, DateTime.utc_now()) do
      # Add a small buffer (5 seconds)
      diff + 5
    else
      _ -> nil
    end
  end

  def cache_ttl_from_published(%{"published" => published}) when is_binary(published) do
    cache_ttl_from_published(published)
  end

  def cache_ttl_from_published(%{data: %{"published" => published}}) when is_binary(published) do
    cache_ttl_from_published(published)
  end

  def cache_ttl_from_published(%{"object" => %{"published" => published}})
      when is_binary(published) do
    cache_ttl_from_published(published)
  end

  def cache_ttl_from_published(_), do: nil

  def get_with_cache(get_fun, cache_bucket, key, identifier, opts \\ [])
      when is_function(get_fun) do
    if some_identifier = some_identifier(key, identifier) do
      cache_key = do_ap_cache_key(key, some_identifier)
      multi_tenant_context = Adapter.get_multi_tenant_context()

      case cachex_fetch(
             cache_bucket,
             cache_key,
             fn ->
               if is_function(get_fun, 2) do
                 get_fun.([{key, identifier}], opts)
               else
                 get_fun.([{key, identifier}])
               end
               |> case do
                 {:ok, object} ->
                   debug("#{cache_bucket}: got and now caching (key: #{cache_key})")
                   debug(object, "got from cache")

                   if key != :json, do: maybe_multi_cache(cache_bucket, object)

                   {:commit, object}

                 {:error, :not_found} ->
                   warn(identifier, "not found with #{inspect(get_fun)} for #{key}")
                   {:commit, :not_found}

                 e ->
                   warn(e, "error attempting to get with #{cache_key} ")
                   {:ignore, e}
               end
             end,
             Keyword.put(opts, :multi_tenant_context, multi_tenant_context)
           ) do
        {:ok, :not_found} ->
          debug(":not_found was cached for #{cache_key}")
          {:error, :not_found}

        {:ok, object} ->
          debug("found in cache for #{cache_key}")
          {:ok, object}

        {:commit, :not_found} ->
          {:error, :not_found}

        {:commit, object} ->
          {:ok, object}

        {:ignore, other} ->
          other

        {:error, :no_cache} ->
          Adapter.set_multi_tenant_context(multi_tenant_context)

          if is_function(get_fun, 2) do
            get_fun.([{key, identifier}], opts)
          else
            get_fun.([{key, identifier}])
          end

        # {:error, "cannot find ownership process"<>_} -> get_fun.([{key, identifier}])
        msg ->
          error(msg)
      end
    else
      warn(identifier, "could not determine identifier for cache key, skipping cache")

      if is_function(get_fun, 2) do
        get_fun.([{key, identifier}], opts)
      else
        get_fun.([{key, identifier}])
      end
    end
  rescue
    e ->
      error(e)

      if is_function(get_fun, 2) do
        get_fun.([{key, identifier}], opts)
      else
        get_fun.([{key, identifier}])
      end
  catch
    e ->
      error(e)
      # workaround :nodedown errors
      if is_function(get_fun, 2) do
        get_fun.([{key, identifier}], opts)
      else
        get_fun.([{key, identifier}])
      end
  end

  # FIXME: should we be caching the objects once, and just using the multiple keys to lookup a unique key?
  defp maybe_multi_cache(:ap_actor_cache, actor) do
    ActivityPub.Actor.set_cache(actor)
    # |> debug()
  end

  defp maybe_multi_cache(:ap_object_cache, object) do
    ActivityPub.Object.set_cache(object)
  end

  defp maybe_multi_cache(_, _) do
    debug("skip caching")
    nil
  end

  def json_with_cache(
        conn \\ nil,
        get_fun,
        cache_bucket,
        id,
        ret_fn \\ &return_json/4,
        opts \\ []
      )

  def json_with_cache(%Plug.Conn{} = conn, get_fun, cache_bucket, id, ret_fn, opts) do
    if Untangle.log_level?(:info),
      do:
        info(
          "#{inspect(request_ip(conn.remote_ip))} / #{inspect(Plug.Conn.get_req_header(conn, "user-agent"))}",
          "request from"
        )

    # ttl = cache_ttl_from_published(obj)
    # cache_opts = if ttl, do: Keyword.put(opts, :ttl, ttl), else: opts

    with {:ok, %{json: json, meta: meta}} <-
           get_with_cache(get_fun, cache_bucket, :json, id, opts) do
      # TODO: cache the actual json binary so it doesn't have to go through Jason each time?
      # FIXME: add a way disable JSON caching in config for cases where a reverse proxy is also doing caching, to avoid storing it twice?

      ret_fn.(conn, meta, json, opts)
    else
      {:error, code, msg} ->
        error_json(conn, msg, code)

      other ->
        error(other, "unhandled case")
        error_json(conn, "server error", 500)
    end
  end

  def json_with_cache(_, get_fun, cache_bucket, id, _ret_fn, opts) do
    with {:ok, %{json: json}} <- get_with_cache(get_fun, cache_bucket, :json, id, opts) do
      # TODO: cache the actual json so it doesn't have to go through Jason each time?
      # FIXME: add a way disable JSON caching in config for cases where a reverse proxy is also doing caching, to avoid storing it twice?
      Jason.encode(json)
    else
      {:error, _code, msg} ->
        %{error: msg}

      _other ->
        %{error: "unknown"}
    end
  end

  def return_json(conn, meta, json, _opts \\ []) do
    conn
    |> PlugHTTPValidator.set(meta)
    #  4.2 hours - TODO: configurable
    |> Plug.Conn.put_resp_header("cache-control", "max-age=#{15120}")
    # RFC 9421 §5.1: advertise that we accept HTTP Message Signatures
    # (skip if client already sent an RFC 9421 signature)
    |> maybe_advertise_accept_signature()
    |> Plug.Conn.put_resp_content_type("application/activity+json")
    |> Phoenix.Controller.json(json)
  end

  @doc """
  Adds `Accept-Signature` response header to advertise RFC 9421 support,
  but skips it if the client already sent an RFC 9421 signature.
  """
  def maybe_advertise_accept_signature(conn) do
    if Plug.Conn.get_req_header(conn, "signature-input") |> Enum.any?() do
      conn
    else
      Plug.Conn.put_resp_header(conn, "accept-signature", "sig1=()")
    end
  end

  def error_json(conn, error, status \\ 500) do
    conn
    |> Plug.Conn.put_status(status)
    # On 401, hint that we accept RFC 9421 signatures
    |> then(fn conn ->
      if status in 401..403, do: maybe_advertise_accept_signature(conn), else: conn
    end)
    |> Phoenix.Controller.json(%{error: error})
  end

  @doc "conditionally update a map"
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, _key, []), do: map
  def maybe_put(map, _key, ""), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  def put_if_present(map, key, value, value_function \\ &{:ok, &1}) when is_map(map) do
    with false <- is_nil(key),
         false <- is_nil(value),
         {:ok, new_value} <- value_function.(value) do
      Map.put(map, key, new_value)
    else
      _ -> map
    end
  end

  def safe_put_in(data, keys, value) when is_map(data) and is_list(keys) do
    Kernel.put_in(data, keys, value)
  rescue
    _ -> data
  end

  def maybe_to_atom(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> str
    end
  end

  def maybe_to_atom(other), do: other

  def single_ap_id_or_object(ap_id) do
    cond do
      is_bitstring(ap_id) ->
        ap_id

      is_map(ap_id) && is_bitstring(ap_id["id"]) ->
        ap_id

      is_list(ap_id) ->
        Enum.at(ap_id, 0)

      true ->
        nil
    end
  end

  def single_ap_id(ap_id) do
    cond do
      is_bitstring(ap_id) ->
        ap_id

      is_map(ap_id) && is_bitstring(ap_id["id"]) ->
        ap_id["id"]

      is_list(ap_id) and is_bitstring(Enum.at(ap_id, 0)) ->
        Enum.at(ap_id, 0)

      is_list(ap_id) and is_map(Enum.at(ap_id, 0)) ->
        Enum.at(ap_id, 0)["id"]

      true ->
        nil
    end
  end

  # def request_ip(conn) do
  # NOTE: now using RemoteIp in plug to avoid needing all this
  # cond do
  #   remote_ip = Code.ensure_compiled?(RemoteIp) and RemoteIp.from(conn.req_headers) ->
  #     remote_ip

  #   cf_connecting_ip = List.first(Plug.Conn.get_req_header(conn, "cf-connecting-ip")) ->
  #     cf_connecting_ip

  #   # List.first(Plug.Conn.get_req_header(conn, "b-forwarded-for")) ->
  #   #   parse_forwarded_for(b_forwarded_for)

  #   x_forwarded_for = List.first(Plug.Conn.get_req_header(conn, "x-forwarded-for")) ->
  #     parse_forwarded_for(x_forwarded_for)

  #   forwarded = List.first(Plug.Conn.get_req_header(conn, "forwarded")) ->
  #     Regex.named_captures(~r/for=(?<for>[^;,]+).*$/, forwarded)
  #     |> Map.get("for")
  #     # IPv6 addresses are enclosed in quote marks and square brackets: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Forwarded
  #     |> String.trim("\"")

  #   true ->
  #     conn.remote_ip
  # end
  # |> request_ip()
  # end
  def request_ip(%{remote_ip: remote_ip}), do: request_ip(remote_ip)

  def request_ip(remote_ip) do
    with {:error, e} <- :inet_parse.ntoa(remote_ip) do
      nil
    else
      ip ->
        to_string(ip)
    end
  end

  # defp parse_forwarded_for(header) do
  #   String.split(header, ",")
  #   |> Enum.map(&String.trim/1)
  #   |> List.first()
  # end

  def service_actor() do
    with {:ok, service_actor} <-
           ActivityPub.Federator.Adapter.get_or_create_service_actor() do
      {:ok, service_actor}
    end
  end

  def service_actor!() do
    with {:ok, service_actor} <-
           ActivityPub.Federator.Adapter.get_or_create_service_actor() do
      service_actor
    else
      e ->
        error(e)
        nil
    end
  end

  @doc """
  Takes a map or keyword list, and returns a map with any atom keys converted to string keys. It can optionally do so recursively.
  """
  def stringify_keys(map, recursive \\ false)
  def stringify_keys(nil, _recursive), do: nil

  def stringify_keys(object, true) when is_map(object) or is_list(object) do
    object
    |> Enum.map(fn {k, v} ->
      {
        maybe_to_string(k),
        stringify_keys(v)
      }
    end)
    |> Enum.into(%{})
  end

  def stringify_keys(object, _) when is_map(object) or is_list(object) do
    object
    |> Enum.map(fn {k, v} -> {maybe_to_string(k), v} end)
    |> Enum.into(%{})
  end

  @doc "Handles multiple cases where the input value is of a different type (atom, list, tuple, etc.) and returns a string representation of it."
  def maybe_to_string(atom) when is_atom(atom) and not is_nil(atom) do
    Atom.to_string(atom)
  end

  def maybe_to_string(list) when is_list(list) do
    # IO.inspect(list, label: "list")
    List.to_string(list)
  end

  def maybe_to_string({key, val}) do
    maybe_to_string(key) <> ": " <> maybe_to_string(val)
  end

  def maybe_to_string(other) do
    to_string(other)
  end

  @doc "Format according to RFC 1123, which is the standard for HTTP dates. Example: `Mon, 15 Apr 2025 14:30:15 GMT`"
  def format_date(date \\ NaiveDateTime.utc_now(Calendar.ISO))

  def format_date(%NaiveDateTime{} = date) do
    # 
    Calendar.strftime(date, "%a, %d %b %Y %H:%M:%S GMT")

    # WIP ^ using built-in elixir functions instead of Timex
    # Timex.lformat!(date, "{WDshort}, {0D} {Mshort} {YYYY} {h24}:{m}:{s} GMT", "en")
  end

  def hash(seed, opts \\ [])

  def hash(seed, opts) when is_binary(seed) do
    :crypto.hash(opts[:algorithm] || :md5, seed)
    |> Base.url_encode64(padding: opts[:padding] || false)
  end

  def hash(seed, opts) when is_atom(seed) do
    seed
    |> Atom.to_string()
    |> hash(opts)
  end

  def short_hash(seed, length, opts \\ []) do
    hash(seed, opts)
    |> binary_part(0, length)
  end
end
