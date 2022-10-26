defmodule ActivityPub.Actor do
  @moduledoc """
  An ActivityPub Actor type and functions for dealing with actors.
  """
  require Ecto.Query
  import ActivityPub.Common
  use Arrows
  import Untangle

  alias ActivityPub.Actor
  alias ActivityPub.Adapter
  alias ActivityPub.Fetcher
  alias ActivityPub.Keys
  alias ActivityPub.WebFinger
  alias ActivityPub.Object

  @supported_actor_types ActivityPub.Utils.supported_actor_types()

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

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
    :pointer_id
  ]

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
  def update_actor(actor_id, %{"id"=>_} = data) do
    # TODO: make better
    debug(actor_id, "Updating actor")
    # dump(ActivityPub.Object.all())

    with {:ok, object} <- update_actor_data_by_ap_id(actor_id, data),
         done = Adapter.update_remote_actor(object),
         {:ok, actor} <- single_by_ap_id(actor_id) do
      set_cache(actor)
    end
  end

  defp public_key_from_data(%{
         "publicKey" => %{"publicKeyPem" => public_key_pem}
       }) do
    key =
      public_key_pem
      |> :public_key.pem_decode()
      |> hd()
      |> :public_key.pem_entry_decode()

    {:ok, key}
  end

  defp public_key_from_data(data) do
    error(data, "Key not found")
  end

  @doc """
  Fetches the public key for given actor AP ID.
  """
  def get_public_key_for_ap_id(ap_id) do
    with {:ok, actor} <- get_or_fetch_by_ap_id(ap_id),
         {:ok, public_key} <- public_key_from_data(actor.data) do
      {:ok, public_key}
    else
      e ->
        error(e)
    end
  end

  defp check_if_time_to_update(actor) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), actor.updated_at) >= 86_400
  end

  @doc """
  Fetches a remote actor by username in `username@domain.tld` format
  """
  def fetch_by_username("@" <> username), do: fetch_by_username(username)

  def fetch_by_username(username) do
    with {:ok, %{"id" => ap_id}} when not is_nil(ap_id) <-
           WebFinger.finger(username) do
      fetch_by_ap_id(ap_id)
    else
      e ->
        warn(e)
        {:error, "No AP id in WebFinger"}
    end
  end

  @doc """
  Tries to get a local actor by username or tries to fetch it remotely if username is provided in `username@domain.tld` format.
  """
  def get_or_fetch_by_username("@" <> username),
    do: get_or_fetch_by_username(username)

  def get_or_fetch_by_username(username) do
    with {:ok, actor} <- get_cached_by_username(username) do
      {:ok, actor}
    else
      _e ->
        with [_nick, domain] <- String.split(username, "@"),
             false <- domain == URI.parse(Adapter.base_url()).host,
             {:ok, actor} <- fetch_by_username(username) do
          {:ok, actor}
        else
          %ActivityPub.Actor{} = actor -> {:ok, actor}
          true -> get_cached_by_username(hd(String.split(username, "@")))
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

  defp username_from_ap_id(ap_id) do
    ap_id
    |> String.split("/")
    |> List.last()
  end

  defp get_local_actor(ap_id) do
    username_from_ap_id(ap_id)
    |> get_by_username()
  end

  defp get_remote_actor(ap_id) do
    with {:ok, actor} <- Object.get_cached_by_ap_id(ap_id),
         false <- check_if_time_to_update(actor),
         actor <- format_remote_actor(actor) do
      Adapter.maybe_create_remote_actor(actor)
      {:ok, actor}
    else
      true ->
        update_actor(ap_id)

      nil ->
        {:error, "Remote actor not found: " <> ap_id}

      {:error, e} ->
        {:error, e}
    end
  end

  def format_username(%{data: data}), do: format_username(data)
  def format_username(%{"id"=> id, "preferredUsername"=>nick}) do
    uri = URI.parse(id)
    port = if uri.port not in [80, 443], do: ":#{uri.port}"

    "#{nick}@#{uri.host}#{port}"
  end

  def format_remote_actor(%Object{} = object) do
    # debug(actor)

    data = object.data

    data =
      cond do
        Map.has_key?(data, "collections") ->
          Map.put(data, "type", "Group")

        # Map.has_key?(data, "resources") ->
        #   Map.put(data, "type", "MN:Collection")

        true ->
          data
      end

    %__MODULE__{
      id: object.id,
      data: data,
      keys: nil,
      local: false,
      ap_id: data["id"],
      username: format_username(data),
      deactivated: deactivated?(object),
      pointer_id: Map.get(object, :pointer_id)
    }
  end

  defp fetch_by_ap_id(ap_id) do
    with {:ok, object} <- Fetcher.fetch_object_from_id(ap_id) |> info() do
      maybe_create_actor_from_object(object)
    end
  end

  def maybe_create_actor_from_object_tuple(%{data: %{"type" => type}} = actor)
      when type in @supported_actor_types do
    with actor <- format_remote_actor(actor) do
      {ok_unwrap(Adapter.maybe_create_remote_actor(actor)), ok_unwrap(set_cache(actor))}
    end
  end

  def maybe_create_actor_from_object_tuple(ap_id) when is_binary(ap_id) do
    with {:ok, object} <- Fetcher.fetch_fresh_object_from_id(ap_id) |> info() do
      maybe_create_actor_from_object_tuple(object)
    end
  end

  def maybe_create_actor_from_object_tuple(object) do
    warn(object, "Skip creating usupported actor type")
    {nil, ok_unwrap(object)}
  end

   def maybe_create_actor_from_object(actor) do
    maybe_create_actor_from_object_tuple(actor)
    |> elem(1)
  end

  @doc """
  Fetches a local actor given its preferred username.
  """
  def get_by_username("@" <> username), do: get_by_username(username)

  def get_by_username(username) do

    with {:ok, actor} <- Adapter.get_actor_by_username(username) do
      {:ok, actor}
    else
      e ->
        warn(e, username)
        {:error, :not_found}
    end
  end

  def get_by_local_id(id) when not is_nil(id) do
    with {:ok, actor} <- Adapter.get_actor_by_id(id) do
      {:ok, actor}
    else
      _e -> {:error, :not_found}
    end
  end

  @doc """
  Fetches an actor given its AP ID.

  Remote actors are first checked if they exist in database and are fetched remotely if they don't.

  Remote actors are also automatically updated every 24 hours.
  """
  @spec get_by_ap_id(String.t()) :: {:ok, Actor.t()} | {:error, any()}
  def get_by_ap_id(ap_id) do
    host = URI.parse(ap_id)
    instance_host = URI.parse(Adapter.base_url())

    if host.host == instance_host.host and host.port == instance_host.port do
      info(ap_id, "assume local actor")
      get_local_actor(ap_id)
    else
      info(ap_id, "assume remote actor")
      get_remote_actor(ap_id)
    end
    # |> info()
    |> case do
      %{} = object -> object
      {:ok, object} -> object
      {:error, e} -> error(e)
      other -> info(other)
    end
  end

  def single_by_ap_id(ap_id) do
    case get_by_ap_id(ap_id) do
      %{} = object -> {:ok, object}
      {:ok, object} -> {:ok, object}
      {:error, e} -> error(e)
      other -> warn(other)
    end
  end

  def get_cached_by_ap_id!(ap_id), do: get_by_ap_id(ap_id)

  def get_or_fetch_by_ap_id(ap_id) do
    case get_cached_by_ap_id(ap_id) |> info() do
      {:ok, actor} -> {:ok, actor}
      _ -> fetch_by_ap_id(ap_id) |> info()
    end
  end

  def set_cache({:ok, actor}), do: set_cache(actor)

  def set_cache(%Actor{} = actor) do
    Cachex.put(:ap_actor_cache, "ap_id:#{actor.ap_id}", actor)
    Cachex.put(:ap_actor_cache, "username:#{actor.username}", actor)
    Cachex.put(:ap_actor_cache, "id:#{actor.id}", actor)
    {:ok, actor}
  end
  def set_cache(e), do: e

  def invalidate_cache(%Actor{} = actor) do
    Cachex.del(:ap_actor_cache, "ap_id:#{actor.ap_id}")
    Cachex.del(:ap_actor_cache, "username:#{actor.username}")
    Cachex.del(:ap_actor_cache, "id:#{actor.id}")
  end

  def get_cached_by_ap_id(%{"id" => ap_id}) when is_binary(ap_id),
    do: get_cached_by_ap_id(ap_id)
  def get_cached_by_ap_id(%{data: %{"id" => ap_id}}) when is_binary(ap_id),
    do: get_cached_by_ap_id(ap_id)
  def get_cached_by_ap_id(ap_id) when is_binary(ap_id) do
    key = "ap_id:#{ap_id}"

    case cachex_fetch(:ap_actor_cache, key, fn ->
           case single_by_ap_id(ap_id) |> info do
             {:ok, actor} -> {:commit, actor}
             {:error, _} -> {:ignore, nil}
           end
         end) do
      {:ok, actor} -> {:ok, actor}
      {:commit, actor} -> {:ok, actor}
      {:ignore, _} -> {:error, :not_found}
      msg -> error(msg)
    end
  end

  def get_cached_by_local_id(id) do
    key = "id:#{id}"

    case cachex_fetch(:ap_actor_cache, key, fn ->
           case get_by_local_id(id) do
             {:ok, actor} ->
               {:commit, actor}

             _ ->
               {:ignore, nil}
           end
         end) do
      {:ok, actor} -> {:ok, actor}
      {:commit, actor} -> {:ok, actor}
      {:ignore, _} -> {:error, :not_found}
      msg -> error(msg)
    end
  end

  def get_cached_by_username("@" <> username),
    do: get_cached_by_username(username)

  def get_cached_by_username(username) do
    key = "username:#{username}"

    try do
      case cachex_fetch(:ap_actor_cache, key, fn ->
             case get_by_username(username) do
               {:ok, actor} -> {:commit, actor}
               {:error, _error} -> {:ignore, nil}
             end
           end) do
        {:ok, actor} -> {:ok, actor}
        {:commit, actor} -> {:ok, actor}
        {:ignore, _} -> {:error, :not_found}
        msg -> error(msg)
      end
    catch e ->
      warn(e, "workaround for :nodedown errors")
      get_by_username(username)
    rescue e ->
      warn(e, "workaround")
      get_by_username(username)
    end
  end

  def get_by_local_id!(id) do
    with {:ok, actor} <- get_cached_by_local_id(id) do
      actor
    else
      {:error, _e} -> nil
    end
  end

  @doc false
  def add_public_key(%{data: _} = actor) do

    with {:ok, actor} <- ensure_keys_present(actor),
         {:ok, _, public_key} <- ActivityPub.Keys.keys_from_pem(actor.keys) do
      public_key = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)
      public_key = :public_key.pem_encode([public_key])

      Map.put(actor, :data,
        Map.merge(actor.data,
          %{"publicKey"=> %{
          "id" => "#{actor.data["id"]}#main-key",
          "owner" => actor.data["id"],
          "publicKeyPem" => public_key
        }}
      ))
    else e ->
      error(e, "Could not add public key")
      actor
    end
  end

  @doc """
  Checks if an actor struct has a non-nil keys field and generates a PEM if it doesn't.
  """
  def ensure_keys_present(actor) do
    if actor.keys do
      {:ok, actor}
    else
      with {:ok, pem} <- Keys.generate_rsa_pem(),
           {:ok, actor} <- Adapter.update_local_actor(actor, %{keys: pem}),
           {:ok, actor} <- set_cache(actor) do
        {:ok, actor}
      else
        e -> error(e, "Could not generate or save keys")
      end
    end
  end

  def get_actor_from_follow(follow) do
    with {:ok, actor} <- get_cached_by_local_id(follow.creator_id) do
      actor
    else
      _ -> nil
    end
  end

  def get_followings(actor) do
    followings =
      Adapter.get_following_local_ids(actor)
      |> Enum.map(&get_by_local_id!/1)
      |> Enum.filter(fn x -> x end)

    {:ok, followings}
  end

  def get_followers(actor) do
    followers =
      Adapter.get_follower_local_ids(actor)
      |> debug("followers")
      |> Enum.map(&get_by_local_id!/1)
      # Filter nils
      |> Enum.filter(fn x -> x end)

    {:ok, followers}
  end

  def get_external_followers(actor) do
    followers =
      Adapter.get_follower_local_ids(actor)
      |> Enum.map(&get_by_local_id!/1)
      # Filter nils
      |> Enum.filter(fn x -> x end)
      # Filter locals
      |> Enum.filter(fn x -> !x.local end)

    {:ok, followers}
  end

  # TODO: add bcc
  def remote_users(_actor, %{data: %{"to" => to}} = data) do
    cc = Map.get(data, "cc", [])

    [to, cc]
    |> Enum.concat()
    |> List.delete(@public_uri)
    |> Enum.map(&get_by_ap_id/1)
    |> Enum.filter(fn actor -> actor && !actor.local end)
  end

  def delete(%Actor{local: false} = actor) do
    invalidate_cache(actor)

    repo().delete(%Object{
      id: actor.id
    })
  end

  # TODO
  def get_and_format_collections_for_actor(_actor) do
    []
  end

  # TODO
  def get_and_format_resources_for_actor(_actor) do
    []
  end

  def update_actor_data_by_ap_id(ap_id, data) when is_binary(ap_id) do
    with {:ok, object} <- Object.single_by_ap_id(ap_id) do
      update_actor_data_by_ap_id(object, data)
    else e ->
      warn(e)
      maybe_create_actor_from_object(data)
    end
  end

  def update_actor_data_by_ap_id(%Object{} = object, data) do
    object
    |> Ecto.Changeset.change(%{
      data: data,
      updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
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

    update_actor_data_by_ap_id(actor.ap_id, new_data)
    # Return Actor
    set_cache(get_by_ap_id(actor.ap_id))
  end

  def reactivate(%Actor{local: false} = actor) do
    new_data =
      actor.data
      |> Map.put("deactivated", false)

    update_actor_data_by_ap_id(actor.ap_id, new_data)
    # Return Actor
    set_cache(get_by_ap_id(actor.ap_id))
  end

  def get_creator_ap_id(actor) do
    with {:ok, actor} <- get_cached_by_local_id(actor.creator_id) do
      actor.ap_id
    else
      {:error, _} -> nil
    end
  end

  def get_community_ap_id(actor) do
    with {:ok, actor} <- get_cached_by_local_id(actor.community_id) do
      actor.ap_id
    else
      {:error, _} -> nil
    end
  end
end
