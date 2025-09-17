defmodule ActivityPub.Utils do
  @moduledoc """
  Misc functions used for federation
  """
  alias ActivityPub.Config
  require ActivityPub.Config
  # alias ActivityPub.Actor
  # alias ActivityPub.Object
  alias ActivityPub.Federator.Adapter
  alias Ecto.UUID
  import Untangle
  # import Ecto.Query

  def repo, do: Process.get(:ecto_repo_module) || ActivityPub.Config.get!(:repo)

  def adapter_fallback() do
    warn("Could not find an ActivityPub adapter, falling back to TestAdapter")

    ActivityPub.TestAdapter
  end

  def make_date do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  # def generate_context_id, do: generate_id("contexts")

  def generate_object_id, do: generate_id("objects") |> debug

  def generate_id(type), do: ap_base_url() <> "/#{type}/#{UUID.generate()}"

  def ap_base_url() do
    ActivityPub.Web.base_url() <> System.get_env("AP_BASE_PATH", "/pub")
  end

  def activitypub_object_headers, do: [{"content-type", "application/activity+json"}]

  def make_json_ld_header(type \\ :object)

  def make_json_ld_header(type) do
    %{
      "@context" => make_json_ld_context_list(type)
    }
  end

  def make_json_ld_context_list(type \\ :object)

  def make_json_ld_context_list(type) do
    json_contexts = Application.get_env(:activity_pub, :json_contexts, [])

    [
      "https://www.w3.org/ns/activitystreams",
      Enum.into(
        stringify_keys(json_contexts[type] || json_contexts[:object]) || %{},
        %{
          "@language" => Adapter.get_locale()
        }
      )
    ]
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

  def some_identifier(%{id: id}) do
    id
  end

  def some_identifier(object) do
    uid(object) || ap_id(object)
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

  def set_repo(repo) when is_binary(repo) do
    String.to_existing_atom(repo)
    |> set_repo()
  end

  def set_repo(nil), do: nil

  def set_repo(repo) do
    if is_atom(repo) and Code.ensure_loaded?(repo) do
      Process.put(:ecto_repo_module, repo)
      ActivityPub.Config.get!(:repo).put_dynamic_repo(repo)
    else
      error(repo, "invalid module")
    end
  end

  def cachex_fetch(cache, key, fallback, options \\ []) when is_function(fallback) do
    if Config.env() == :test do
      # FIXME: temporary workaround for Ecto sandbox / ExUnit issues
      fallback.()
    else
      ecto_repo_module = ProcessTree.get(:ecto_repo_module)

      Cachex.fetch(
        cache,
        key,
        fn _ ->
          set_repo(ecto_repo_module)

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

  def get_with_cache(get_fun, cache_bucket, key, identifier, opts \\ [])
      when is_function(get_fun) do
    if some_identifier = some_identifier(identifier) do
      cache_key = "#{short_hash(repo(), 6)}:#{key}:#{some_identifier}"
      mock_fun = Process.get(Tesla.Mock)

      case cachex_fetch(cache_bucket, cache_key, fn ->
             maybe_put_mock(mock_fun)

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
           end) do
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
          maybe_put_mock(mock_fun)

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

  defp maybe_put_mock(mock_fun) do
    # so our test mocks carry over when fetching
    if(is_function(mock_fun)) do
      Process.put(Tesla.Mock, mock_fun)
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

    with {:ok, %{json: json, meta: meta}} <-
           get_with_cache(get_fun, cache_bucket, :json, id, opts) do
      # TODO: cache the actual json so it doesn't have to go through Jason each time?
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
    |> Plug.Conn.put_resp_content_type("application/activity+json")
    |> Phoenix.Controller.json(json)
  end

  def error_json(conn, error, status \\ 500) do
    conn
    |> Plug.Conn.put_status(status)
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
  def request_ip(remote_ip), do: to_string(:inet_parse.ntoa(remote_ip))
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
