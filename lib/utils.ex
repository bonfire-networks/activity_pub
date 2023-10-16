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

  def ok_unwrap(val, fallback \\ nil)
  def ok_unwrap({:ok, val}, _fallback), do: val
  def ok_unwrap({:error, _val}, fallback), do: fallback
  def ok_unwrap(:error, fallback), do: fallback
  def ok_unwrap(val, fallback), do: val || fallback

  def as_local_public, do: ActivityPub.Web.base_url() <> "/#Public"

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
    json_contexts = Application.get_env(:activity_pub, :json_contexts, [])

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        Enum.into(
          stringify_keys(json_contexts[type]) || %{},
          %{
            "@language" => Adapter.get_locale()
          }
        )
      ]
    }
  end

  @doc """
  Determines if an object or an activity is public.
  """

  # TODO: consolidate this and the others below?
  # def public?(data) do
  #   recipients = List.wrap(data["to"]) ++ List.wrap(data["cc"])

  #   cond do
  #     recipients == [] ->
  #       # let's NOT assume things are public by default?
  #       false

  #     Enum.member?(recipients, ActivityPub.Config.public_uri()) or
  #       Enum.member?(recipients, "Public") or
  #         Enum.member?(recipients, "as:Public") ->
  #       # see note at https://www.w3.org/TR/activitypub/#public-addressing
  #       true

  #     true ->
  #       false
  #   end
  # end

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

  def public?(_, object_data) do
    public?(object_data)
  end

  def public?(_, _) do
    false
  end

  def public?(%{data: data}), do: public?(data)
  def public?(%{"type" => "Tombstone"}), do: false
  def public?(%{"type" => "Move"}), do: true
  # for bookwyrm
  def public?(%{"publishedDate" => _}) do
    true
  end

  def public?(%{"directMessage" => true}), do: false

  def public?(data) do
    label_in_message?(ActivityPub.Config.public_uri(), data) or
      label_in_message?(as_local_public(), data)
  end

  @spec label_in_collection?(any(), any()) :: boolean()
  defp label_in_collection?(ap_id, coll) when is_binary(coll), do: ap_id == coll
  defp label_in_collection?(ap_id, coll) when is_list(coll), do: ap_id in coll
  defp label_in_collection?(_, _), do: false

  @spec label_in_message?(String.t(), map()) :: boolean()
  def label_in_message?(label, params),
    do:
      [params["to"], params["cc"], params["bto"], params["bcc"]]
      |> Enum.any?(&label_in_collection?(label, &1))

  @doc "Takes a string and returns true if it is a valid UUID (Universally Unique Identifier)"
  def is_uuid?(str) do
    with true <- is_binary(str) and byte_size(str) == 36,
         {:ok, _} <- Ecto.UUID.cast(str) do
      true
    else
      _ -> false
    end
  end

  def is_ulid?(str) when is_binary(str) and byte_size(str) == 26 do
    with :error <- Pointers.ULID.cast(str) do
      false
    else
      _ -> true
    end
  end

  def is_ulid?(_), do: false

  def ulid(%{pointer_id: id}) when is_binary(id), do: ulid(id)
  def ulid(%{id: id}) when is_binary(id), do: ulid(id)

  def ulid(input) do
    if is_ulid?(input) do
      input
    else
      warn(input, "Expected a ULID ID (or an object with one), but got")
      nil
    end
  end

  def ap_id(%{ap_id: id}), do: id
  def ap_id(%{data: %{"id" => id}}), do: id
  def ap_id(%{"id" => id}), do: id

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
      ecto_repo_module = Process.get(:ecto_repo_module)

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

  def get_with_cache(get_fun, cache_bucket, key, identifier) when is_function(get_fun) do
    cache_key = "#{key}:#{identifier}"
    mock_fun = Process.get(Tesla.Mock)

    case cachex_fetch(cache_bucket, cache_key, fn ->
           maybe_put_mock(mock_fun)

           case get_fun.([{key, identifier}]) do
             {:ok, object} ->
               debug("#{cache_bucket}: got and now caching (#{key}: #{identifier})")
               debug(object)

               if key != :json, do: maybe_multi_cache(cache_bucket, object)

               {:commit, object}

             e ->
               warn(e, "nothing with #{key} - #{identifier} ")
               {:ignore, e}
           end
         end) do
      {:ok, object} ->
        debug("found in cache - #{key}: #{identifier}")
        {:ok, object}

      {:commit, object} ->
        {:ok, object}

      {:ignore, other} ->
        other

      {:error, :no_cache} ->
        maybe_put_mock(mock_fun)
        get_fun.([{key, identifier}])

      # {:error, "cannot find ownership process"<>_} -> get_fun.([{key, identifier}])
      msg ->
        error(msg)
    end
  rescue
    _ ->
      get_fun.([{key, identifier}])
  catch
    _ ->
      # workaround :nodedown errors
      get_fun.([{key, identifier}])
  end

  defp maybe_put_mock(mock_fun) do
    # so our test mocks carry over when fetching
    if(is_function(mock_fun)) do
      Process.put(Tesla.Mock, mock_fun)
    end
  end

  # FIXME: should we be caching the objects once, and just using the multiple keys to lookup a unique key?
  defp maybe_multi_cache(:ap_actor_cache, %{data: %{"type" => type}} = actor)
       when ActivityPub.Config.is_in(type, :supported_actor_types) do
    ActivityPub.Actor.set_cache(actor)
    |> debug
  end

  defp maybe_multi_cache(:ap_object_cache, object) do
    ActivityPub.Object.set_cache(object)
  end

  defp maybe_multi_cache(_, _) do
    debug("skip caching")
    nil
  end

  def json_with_cache(conn \\ nil, get_fun, cache_bucket, id)

  def json_with_cache(%Plug.Conn{} = conn, get_fun, cache_bucket, id) do
    if Untangle.log_level?(:info),
      do:
        info(
          "#{inspect(request_ip(conn))} / #{inspect(Plug.Conn.get_req_header(conn, "user-agent"))}",
          "request from"
        )

    with {:ok, %{json: json, meta: meta}} <- get_with_cache(get_fun, cache_bucket, :json, id) do
      # TODO: cache the actual json so it doesn't have to go through Jason each time?
      # FIXME: add a way disable JSON caching in config for cases where a reverse proxy is also doing caching, to avoid storing it twice?

      conn
      |> PlugHTTPValidator.set(meta |> debug)
      #  4.2 hours - TODO: configurable
      |> Plug.Conn.put_resp_header("cache-control", "max-age=#{15120}")
      |> Plug.Conn.put_resp_content_type("application/activity+json")
      |> Phoenix.Controller.json(json)
    else
      {:error, code, msg} ->
        error_json(conn, msg, code)

      other ->
        error(other, "unhandled case")
        error_json(conn, "server error", 500)
    end
  end

  def json_with_cache(_, get_fun, cache_bucket, id) do
    with {:ok, %{json: json}} <- get_with_cache(get_fun, cache_bucket, :json, id) do
      # TODO: cache the actual json so it doesn't have to go through Jason each time?
      # FIXME: add a way disable JSON caching in config for cases where a reverse proxy is also doing caching, to avoid storing it twice?
      Jason.encode(json)
    else
      {:error, code, msg} ->
        %{error: msg}

      other ->
        %{error: "unknown"}
    end
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

  def request_ip(conn) do
    cond do
      remote_ip = Code.ensure_compiled?(RemoteIp) and RemoteIp.from(conn.req_headers) ->
        remote_ip

      # TODO: just use RemoteIp in plug and avoid needed this whole function?

      cf_connecting_ip = List.first(Plug.Conn.get_req_header(conn, "cf-connecting-ip")) ->
        cf_connecting_ip

      # List.first(Plug.Conn.get_req_header(conn, "b-forwarded-for")) ->
      #   parse_forwarded_for(b_forwarded_for)

      x_forwarded_for = List.first(Plug.Conn.get_req_header(conn, "x-forwarded-for")) ->
        parse_forwarded_for(x_forwarded_for)

      forwarded = List.first(Plug.Conn.get_req_header(conn, "forwarded")) ->
        Regex.named_captures(~r/for=(?<for>[^;,]+).*$/, forwarded)
        |> Map.get("for")
        # IPv6 addresses are enclosed in quote marks and square brackets: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Forwarded
        |> String.trim("\"")

      true ->
        to_string(:inet_parse.ntoa(conn.remote_ip))
    end
  end

  defp parse_forwarded_for(header) do
    String.split(header, ",")
    |> Enum.map(&String.trim/1)
    |> List.first()
  end

  def service_actor() do
    with {:ok, service_actor} <-
           ActivityPub.Federator.Adapter.get_or_create_service_actor() do
      {:ok, service_actor}
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
    maybe_to_string(key) <> ":" <> maybe_to_string(val)
  end

  def maybe_to_string(other) do
    to_string(other)
  end

  def format_date(date \\ NaiveDateTime.utc_now(Calendar.ISO))

  def format_date(%NaiveDateTime{} = date) do
    # TODO: use built-in elixir function or CLDR instead?
    # Timex.format!(date, "{WDshort}, {0D} {Mshort} {YYYY} {h24}:{m}:{s} GMT")
    Timex.lformat!(date, "{WDshort}, {0D} {Mshort} {YYYY} {h24}:{m}:{s} GMT", "en")
  end
end
