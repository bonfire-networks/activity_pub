defmodule ActivityPub.Actor do
  @moduledoc """
  An ActivityPub Actor type and functions for dealing with actors.
  """
  require Ecto.Query
  import ActivityPub.Utils
  use Arrows
  import Untangle
  require ActivityPub.Config

  alias ActivityPub.Actor
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Federator.WebFinger
  alias ActivityPub.Object
  alias ActivityPub.Utils

  require Logger

  @type t :: %Actor{}
  # @type t :: %Actor{ # FIXME
  #         id: binary(),
  #         data: map(),
  #         local: boolean(),
  #         keys: binary(),
  #         ap_id: binary(),
  #         username: binary(),
  #         deactivated: boolean(),
  #         pointer_id: binary()
  #       }

  defstruct [
    :id,
    :data,
    :local,
    :keys,
    :ap_id,
    :username,
    :deactivated,
    :pointer_id,
    :pointer,
    :updated_at
  ]

  def get_cached(id: id), do: do_get_cached(:id, id)

  # def get_cached(pointer: %{id: id} = pointer),
  #   do: get_cached(pointer: id) ~> Map.put(:pointer, pointer) |> ok()

  def get_cached(pointer: id), do: do_get_cached(:pointer, id)
  def get_cached(username: username), do: do_get_cached(:username, username)
  def get_cached(ap_id: ap_id) when is_binary(ap_id), do: do_get_cached(:ap_id, ap_id)

  def get_cached(_: %Actor{} = actor), do: actor

  def get_cached(id: %{id: id}) when is_binary(id), do: get_cached(id: id)
  def get_cached([{_, %{ap_id: ap_id}}]) when is_binary(ap_id), do: get_cached(ap_id: ap_id)
  def get_cached([{_, %{"id" => ap_id}}]) when is_binary(ap_id), do: get_cached(ap_id: ap_id)

  def get_cached([{_, %{data: %{"id" => ap_id}}}]) when is_binary(ap_id),
    do: get_cached(ap_id: ap_id)

  def get_cached(username: "@" <> username), do: get_cached(username: username)

  def get_cached(id) when is_binary(id) do
    if Utils.is_ulid?(id) do
      get_cached(pointer: id)
    else
      if String.starts_with?(id, "http") do
        get_cached(ap_id: id)
      else
        if Utils.is_uuid?(id) do
          get_cached(id: id)
        else
          get_cached(username: id)
        end
      end
    end
  end

  def get_cached(opts), do: get(opts)

  defp do_get_cached(key, val), do: Utils.get_with_cache(&get/1, :ap_actor_cache, key, val)

  def get_cached!(opts) do
    with {:ok, actor} <- get_cached(opts) do
      actor
    else
      {:error, _e} -> nil
    end
  end

  @doc """
  Fetches a local actor given its preferred username.
  """
  defp get(username: "@" <> username), do: get_cached(username: username)

  defp get(username: username) do
    with {:ok, actor} <- Adapter.get_actor_by_username(username) do
      {:ok, actor}
    else
      e ->
        error(e, "Adapter did not find a local actor")
        {:error, :not_found}
    end
  end

  defp get(id: id) when not is_nil(id) do
    with {:ok, actor} <- ActivityPub.Object.get_cached(id: id) do
      {:ok, format_remote_actor(actor)}
    else
      e ->
        error(e, "Not a remote actor (so cannot query by UUID)")
        {:error, :not_found}
    end
  end

  defp get(pointer: id) when not is_nil(id) do
    with {:ok, actor} <- ActivityPub.Object.get_cached(pointer: id) do
      {:ok, format_remote_actor(actor)}
    else
      _ ->
        with {:ok, actor} <- Adapter.get_actor_by_id(id) do
          {:ok, actor}
        else
          e ->
            error(e, "Adapter did not find a local actor")
            {:error, :not_found}
        end
    end
  end

  # defp get(ap_id: id) when not is_nil(id) do
  #   with {:ok, actor} <- ActivityPub.Object.get_cached(ap_id: id) do
  #     {:ok, format_remote_actor(actor)}
  #   else _ ->
  #      with {:ok, actor} <- Adapter.get_actor_by_ap_id(id) do
  #       {:ok, actor}
  #     else
  #       e ->
  #         error(e, "Adapter did not return an actor")
  #         {:error, :not_found}
  #     end
  #   end
  # end

  @doc """
  Fetches an actor given its AP ID.

  Remote actors are first checked if they exist in database and are fetched remotely if they don't.

  Remote actors are also automatically updated every 24 hours.
  """
  @spec get(ap_id: String.t()) :: {:ok, Actor.t()} | {:error, any()}
  defp get(ap_id: ap_id) when is_binary(ap_id) do
    with {:ok, actor} <- Adapter.get_actor_by_ap_id(ap_id) do
      {:ok, actor}
    else
      e ->
        debug(e, "result of Adapter.get_actor_by_ap_id")
        get_remote_actor(ap_id)
    end
  end

  defp get(%{data: %{"id" => ap_id}}) when is_binary(ap_id), do: get(ap_id: ap_id)
  defp get(%{"id" => ap_id}) when is_binary(ap_id), do: get(ap_id: ap_id)
  defp get(ap_id: ap_id), do: get(ap_id)

  defp get(opts) do
    error(opts, "Unexpected args")
    raise "Unexpected args when attempting to get an actor"
  end

  @doc """
  Updates an existing actor struct by its AP ID.
  """
  @spec update_actor(String.t()) :: {:ok, Actor.t()} | {:error, any()}
  def update_actor(actor_id) when is_binary(actor_id) do
    # TODO: make better
    debug(actor_id, "Updating actor")

    with {:ok, data} <- Fetcher.fetch_remote_object_from_id(actor_id) |> info do
      update_actor(actor_id, data)
    end
  end

  def update_actor(actor_id, %{data: data}), do: update_actor(actor_id, data)

  def update_actor(actor_id, %{"id" => _} = data) do
    # TODO: make better
    debug(actor_id, "Updating actor")
    # dump(ActivityPub.Object.all())

    with {:ok, object} <- update_actor_data(actor_id, data),
         done = Adapter.update_remote_actor(object),
         {:ok, actor} <- get(ap_id: actor_id) do
      set_cache(actor)
    end
  end

  @doc """
  Fetches the public key for given actor AP ID.
  """
  def get_public_key_for_ap_id(ap_id) do
    with %ActivityPub.Actor{} = actor <- ok_unwrap(get_or_fetch_by_ap_id(ap_id)),
         {:ok, public_key} <- public_key_from_data(actor.data) do
      {:ok, public_key}
    else
      e ->
        error(e)
    end
  end

  defp public_key_from_data(%{
         "publicKey" => %{"publicKeyPem" => public_key_pem}
       })
       when is_binary(public_key_pem) do
    {:ok, public_key_pem}
  end

  defp public_key_from_data(data) do
    error(data, "Key not found")
  end

  defp check_if_time_to_update(actor) do
    (NaiveDateTime.diff(NaiveDateTime.utc_now(Calendar.ISO), actor.updated_at) >= 86_400)
    |> info("Time to update the actor?")
  end

  @doc """
  Fetches a remote actor by username in `username@domain.tld` format
  """
  def fetch_by_username(username, opts \\ [])
  def fetch_by_username("@" <> username, opts), do: fetch_by_username(username, opts)

  def fetch_by_username(username, opts) do
    with {:ok, %{"id" => ap_id}} when not is_nil(ap_id) <-
           WebFinger.finger(username) do
      fetch_by_ap_id(ap_id, opts)
    else
      {:error, e} when is_binary(e) ->
        e

      e ->
        warn(e)
        {:error, "No AP id in WebFinger"}
    end
  end

  @doc """
  Tries to get a local actor by username or tries to fetch it remotely if username is provided in `username@domain.tld` format.
  """
  def get_or_fetch_by_username(username, opts \\ [])

  def get_or_fetch_by_username("@" <> username, opts),
    do: get_or_fetch_by_username(username, opts)

  def get_or_fetch_by_username(username, opts) do
    with {:ok, actor} <- get_cached(username: username) do
      {:ok, actor}
    else
      _e ->
        with [_nick, domain] <- String.split(username, "@"),
             false <- domain == URI.parse(Adapter.base_url()).host,
             {:ok, actor} <- fetch_by_username(username, opts) do
          {:ok, actor}
        else
          %ActivityPub.Actor{} = actor -> {:ok, actor}
          true -> get_cached(username: hd(String.split(username, "@")))
          {:error, reason} -> error(reason)
          e -> error(e, "Actor not found: #{username}")
        end
    end
  end

  def get_or_fetch(username_or_uri) do
    if String.starts_with?(username_or_uri, "http"),
      do: get_or_fetch_by_ap_id(username_or_uri),
      else: get_or_fetch_by_username(username_or_uri)
  end

  # defp username_from_ap_id(ap_id) do
  #   ap_id
  #   |> String.split("/")
  #   |> List.last()
  # end

  def get_remote_actor(ap_id, maybe_create \\ true) do
    # raise "STOOOP"

    with {:ok, actor} <- Object.get_cached(ap_id: ap_id),
         false <- check_if_time_to_update(actor),
         actor <- format_remote_actor(actor),
         {:ok, adapter_actor} <-
           if(maybe_create, do: Adapter.maybe_create_remote_actor(actor), else: {:ok, nil}),
         actor <- Map.put(actor, :pointer, adapter_actor) do
      {:ok, actor}
    else
      true ->
        update_actor(ap_id)

      nil ->
        error(ap_id, "Remote actor not found")

      {:ok, actor} ->
        {:ok, actor}

      %Actor{} = actor ->
        {:ok, actor}

      {:error, e} ->
        {:error, e}
    end
  end

  def format_username(%{data: data}), do: format_username(data)

  def format_username(%{"id" => ap_id, "preferredUsername" => nick}) do
    format_username(ap_id, nick)
  end

  def format_username(ap_id) when is_binary(ap_id) do
    uri = URI.parse(ap_id)
    format_username(uri, String.split(uri.path, "/") |> List.last())
  end

  def format_username(%{"object" => object}) do
    format_username(object)
  end

  def format_username(other) do
    warn(other, "Dunno how to format_username for")
    nil
  end

  def format_username(ap_id, nick) when is_binary(ap_id) do
    format_username(URI.parse(ap_id), nick)
  end

  def format_username(%URI{} = uri, nick) do
    port = if uri.port not in [80, 443], do: ":#{uri.port}"

    "#{nick}@#{uri.host}#{port}"
  end

  def format_remote_actor(%Object{data: data} = object) do
    # debug(actor)

    data =
      cond do
        Map.has_key?(data, "collections") ->
          Map.put_new(data, "type", "Group")

        # Map.has_key?(data, "resources") ->
        #   Map.put(data, "type", "MN:Collection")

        true ->
          data
      end

    %__MODULE__{
      id: object.id,
      data: data,
      keys: data["publicKey"]["publicKeyPem"],
      local: object.local,
      ap_id: data["id"],
      username: format_username(data),
      deactivated: deactivated?(object),
      pointer_id: object.pointer_id,
      pointer: object.pointer,
      updated_at: object.updated_at
    }
  end

  def format_remote_actor(%__MODULE__{} = actor) do
    actor
  end

  defp fetch_by_ap_id(ap_id, opts \\ []) when is_binary(ap_id) do
    Fetcher.fetch_object_from_id(ap_id, opts)
  end

  defp fetch_fresh_by_ap_id(ap_id) when is_binary(ap_id) do
    Fetcher.fetch_fresh_object_from_id(ap_id)
  end

  def maybe_create_actor_from_object(actor) do
    case do_maybe_create_actor_from_object(actor) do
      {:ok, %Actor{} = actor} ->
        {:ok, actor}

      {:ok, %{} = object} ->
        debug(object, "Not an actor?")
        {:ok, object}

      e ->
        error(e, "Could not find or create an actor")
    end
  end

  defp do_maybe_create_actor_from_object(%{data: %{"type" => type}} = actor)
       when ActivityPub.Config.is_in(type, :supported_actor_types) do
    with actor <- format_remote_actor(actor),
         {:ok, adapter_actor} <- Adapter.maybe_create_remote_actor(actor),
         {:ok, actor} <- set_cache(actor) do
      {:ok, actor |> Map.put(:pointer, adapter_actor)}
    end
  end

  # defp do_maybe_create_actor_from_object(ap_id) when is_binary(ap_id) do
  #   with {:ok, object} <- Fetcher.fetch_fresh_object_from_id(ap_id) |> info() do
  #     do_maybe_create_actor_from_object(object)
  #   end
  # end
  defp do_maybe_create_actor_from_object({:ok, object}), do: {:ok, object}
  defp do_maybe_create_actor_from_object(object), do: object

  def get_or_fetch_by_ap_id(ap_id, maybe_create \\ true)
  def get_or_fetch_by_ap_id(%Actor{data: _} = actor, _), do: actor

  def get_or_fetch_by_ap_id(%{"id" => id}, maybe_create),
    do: get_or_fetch_by_ap_id(id, maybe_create)

  def get_or_fetch_by_ap_id(ap_id, maybe_create) do
    case get_remote_actor(ap_id, maybe_create) |> debug() do
      {:ok, actor} ->
        {:ok, actor}

      other ->
        debug(ap_id, "not an known remote actor, try fetching")

        fetch_fresh_by_ap_id(ap_id)
        |> debug()
    end
  end

  def set_cache({:ok, actor}), do: set_cache(actor)

  def set_cache(%Actor{} = actor) do
    # TODO: store in cache only once, and only IDs for the others
    for key <-
          [
            "id:#{actor.id}",
            "ap_id:#{actor.ap_id}",
            "pointer:#{actor.pointer_id}",
            "username:#{actor.username}"
          ]
          |> debug() do
      Cachex.put(:ap_actor_cache, key, actor)
    end

    {:ok, actor}
  end

  def set_cache(e), do: error(e, "Not an actor")

  def invalidate_cache(%Actor{} = actor) do
    Cachex.del(:ap_actor_cache, "id:#{actor.id}")
    Cachex.del(:ap_actor_cache, "ap_id:#{actor.ap_id}")
    Cachex.del(:ap_actor_cache, "pointer:#{actor.pointer_id}")
    Cachex.del(:ap_actor_cache, "username:#{actor.username}")

    Cachex.del(:ap_actor_cache, "json:#{actor.username}")
    Object.invalidate_cache(actor)
  end

  defp get_actor_from_follow(follow) do
    with {:ok, actor} <- get_cached(pointer: follow.creator_id) do
      actor
    else
      _ -> nil
    end
  end

  def get_followings(actor) do
    followings =
      Adapter.get_following_local_ids(actor)
      |> Enum.map(&get_cached!(pointer: &1))
      |> Enum.filter(fn x -> x end)

    {:ok, followings}
  end

  def get_followers(actor) do
    followers =
      Adapter.get_follower_local_ids(actor)
      |> debug("followers")
      |> Enum.map(&get_cached!(pointer: &1))
      # Filter nils
      |> Enum.filter(fn x -> x end)

    {:ok, followers}
  end

  def get_external_followers(actor) do
    followers =
      get_followers(actor)
      # Filter locals
      ~> Enum.filter(fn x -> !x.local end)

    {:ok, followers}
  end

  def delete(%Actor{local: false} = actor) do
    invalidate_cache(actor)

    repo().delete(%Object{
      id: actor.id
    })
  end

  # TODO
  defp get_and_format_collections_for_actor(_actor) do
    []
  end

  # TODO
  defp get_and_format_resources_for_actor(_actor) do
    []
  end

  defp update_actor_data(%{ap_id: ap_id}, data) when is_binary(ap_id) do
    update_actor_data(ap_id, data)
  end

  defp update_actor_data(%{"actor" => ap_id}, data) when is_binary(ap_id) do
    update_actor_data(ap_id, data)
  end

  defp update_actor_data(%{"id" => ap_id}, data) when is_binary(ap_id) do
    update_actor_data(ap_id, data)
  end

  defp update_actor_data(ap_id, data) when is_binary(ap_id) do
    with {:ok, object} <- Object.get_uncached(ap_id: ap_id) do
      update_actor_data(object, data)
      {:ok, object}
    else
      e ->
        warn(e)
        fetch_by_ap_id(ap_id)
    end
  end

  defp update_actor_data(%Object{} = object, data) do
    object
    |> Ecto.Changeset.change(%{
      data: data,
      updated_at: NaiveDateTime.utc_now(Calendar.ISO) |> NaiveDateTime.truncate(:second)
    })
    |> Object.update_and_set_cache()
  end

  defp deactivated?(%Object{} = actor) do
    actor.data["deactivated"] == true
  end

  def deactivate(%Actor{local: false} = actor) do
    new_data =
      actor.data
      |> Map.put("deactivated", true)

    update_actor_data(actor, new_data)
    # Return Actor
    set_cache(get(ap_id: actor.ap_id))
  end

  def reactivate(%Actor{local: false} = actor) do
    new_data =
      actor.data
      |> Map.put("deactivated", false)

    update_actor_data(actor, new_data)
    # Return Actor
    set_cache(get(ap_id: actor.ap_id))
  end

  defp get_creator_ap_id(actor) do
    with {:ok, actor} <- get_cached(pointer: actor.creator_id) do
      actor.ap_id
    else
      {:error, _} -> nil
    end
  end

  defp get_community_ap_id(actor) do
    with {:ok, actor} <- get_cached(pointer: actor.community_id) do
      actor.ap_id
    else
      {:error, _} -> nil
    end
  end

  def check_actor_is_active(actor) do
    if not is_nil(actor) do
      with {:ok, %{deactivated: true}} <- get_cached(ap_id: actor) do
        error(actor, "Actor deactivated")
        :reject
      else
        _ ->
          :ok
      end
    else
      :ok
    end
  end

  def actor_url(%{preferred_username: username}), do: actor_url(username)

  def actor_url(username) when is_binary(username),
    do: Utils.ap_base_url() <> "/actors/" <> username

  def actor?(%{data: %{"type" => type}} = _object)
      when ActivityPub.Config.is_in(type, :supported_actor_types),
      do: true

  def actor?(_), do: false
end
