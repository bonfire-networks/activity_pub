defmodule ActivityPub.Utils do
  @moduledoc """
  Misc functions used for federation
  """
  alias ActivityPub.Config
  # alias ActivityPub.Actor
  # alias ActivityPub.Object
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

  def make_json_ld_header do
    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        Map.merge(
          %{
            "@language" => Application.get_env(:activity_pub, :default_language, "und")
          },
          Application.get_env(:activity_pub, :json_contexts, %{
            "Hashtag" => "as:Hashtag"
          })
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

  def public?(%{"to" => _} = activity_data, %{"to" => _} = object_data) do
    public?(activity_data) && public?(object_data)
  end

  def public?(%{"to" => _} = activity_data, _) do
    public?(activity_data)
  end

  def public?(_, %{"to" => _} = object_data) do
    public?(object_data)
  end

  def public?(_, _) do
    false
  end

  def public?(%{data: %{"type" => "Tombstone"}}), do: false
  def public?(%{data: %{"type" => "Move"}}), do: true
  def public?(%{data: data}), do: public?(data)
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
    with true <- is_binary(str),
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

    case cachex_fetch(cache_bucket, cache_key, fn ->
           case get_fun.([{key, identifier}]) do
             {:ok, object} ->
               debug("got and now caching - #{key}: #{identifier}")
               {:commit, object}

             e ->
               info(e, "nothing with #{key} - #{identifier} ")
               {:ignore, e}
           end
         end) do
      {:ok, object} ->
        debug("found in cache - #{key}: #{identifier}")
        {:ok, object}

      {:commit, object} ->
        debug("found in cache - #{key}: #{identifier}")
        {:ok, object}

      {:ignore, other} ->
        other

      {:error, :no_cache} ->
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

  def json_with_cache(conn, get_fun, cache_bucket, id) do
    if Untangle.log_level?(:info),
      do:
        info(
          "#{request_ip(conn)} / #{Plug.Conn.get_req_header(conn, "user-agent")}",
          "request from"
        )

    with {:ok, json} when is_map(json) <- get_with_cache(get_fun, cache_bucket, :json, id) do
      # TODO: cache the actual json so it doesn't have to go through Jason each time?

      conn
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
end
