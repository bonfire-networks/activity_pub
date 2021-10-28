defmodule ActivityPub.Actor do
  @moduledoc """
  Functions for dealing with ActivityPub actors.
  """
  require Ecto.Query

  alias ActivityPub.Actor
  alias ActivityPub.Adapter
  alias ActivityPub.Fetcher
  alias ActivityPub.Keys
  alias ActivityPub.WebFinger
  alias ActivityPub.Object

  import ActivityPub.Common

  require Logger

  @type t :: %Actor{
          id: binary(),
          data: map(),
          local: boolean(),
          keys: binary(),
          ap_id: binary(),
          username: binary(),
          deactivated: boolean(),
          pointer_id: binary()
        }

  defstruct [:id, :data, :local, :keys, :ap_id, :username, :deactivated, :pointer_id]

  @doc """
  Updates an existing actor struct by its AP ID.
  """
  @spec update_actor(String.t()) :: {:ok, Actor.t()} | {:error, any()}
  def update_actor(actor_id) do
    # TODO: make better
    Logger.info("Updating actor #{actor_id}")

    with {:ok, data} <- Fetcher.fetch_remote_object_from_id(actor_id),
         {:ok, object} <- update_actor_data_by_ap_id(actor_id, data),
         :ok <- Adapter.update_remote_actor(object),
         {:ok, actor} <- get_by_ap_id(actor_id) do
      set_cache(actor)
    end
  end

  defp public_key_from_data(%{"publicKey" => %{"publicKeyPem" => public_key_pem}}) do
    key =
      public_key_pem
      |> :public_key.pem_decode()
      |> hd()
      |> :public_key.pem_entry_decode()

    {:ok, key}
  end

  defp public_key_from_data(_), do: {:error, "Key not found"}

  @doc """
  Fetches the public key for given actor AP ID.
  """
  def get_public_key_for_ap_id(ap_id) do
    with {:ok, actor} <- get_or_fetch_by_ap_id(ap_id),
         {:ok, public_key} <- public_key_from_data(actor.data) do
      {:ok, public_key}
    else
      _ -> :error
    end
  end

  defp check_if_time_to_update(actor) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), actor.updated_at) >= 86_400
  end

  @doc """
  Fetches a remote actor by username in `username@domain.tld` format
  """
  def fetch_by_username(username) do
    with {:ok, %{"id" => ap_id}} when not is_nil(ap_id) <- WebFinger.finger(username) do
      fetch_by_ap_id(ap_id)
    else
      _e -> {:error, "No AP id in WebFinger"}
    end
  end

  @doc """
  Tries to get a local actor by username or tries to fetch it remotely if username is provided in `username@domain.tld` format.
  """
  def get_or_fetch_by_username(username) do
    with {:ok, actor} <- get_cached_by_username(username) do
      {:ok, actor}
    else
      _e ->
        with [_nick, _domain] <- String.split(username, "@"),
             {:ok, actor} <- fetch_by_username(username) do
          {:ok, actor}
        else
          _e -> {:error, "not found " <> username}
        end
    end
  end

  defp username_from_ap_id(ap_id) do
    ap_id
    |> String.split("/")
    |> List.last()
  end

  defp get_local_actor(ap_id) do
    username = username_from_ap_id(ap_id)
    get_by_username(username)
  end

  defp get_remote_actor(ap_id) do
    with %Object{} = actor <- Object.get_cached_by_ap_id(ap_id),
         false <- check_if_time_to_update(actor),
         actor <- format_remote_actor(actor) do
      Adapter.maybe_create_remote_actor(actor)
      {:ok, actor}
    else
      true ->
        update_actor(ap_id)

      nil ->
        {:error, "not found"}

      {:error, e} ->
        {:error, e}
    end
  end

  def format_remote_actor(%Object{} = actor) do
    username = actor.data["preferredUsername"] <> "@" <> URI.parse(actor.data["id"]).host
    data = actor.data

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
      id: actor.id,
      data: data,
      keys: nil,
      local: false,
      ap_id: actor.data["id"],
      username: username,
      deactivated: deactivated?(actor),
      pointer_id: Map.get(actor, :pointer_id)
    }
  end

  defp fetch_by_ap_id(ap_id) do
    with {:ok, object} <- Fetcher.fetch_object_from_id(ap_id) do
      maybe_create_actor_from_object(object)
    end
  end

  def maybe_create_actor_from_object(object) do
    with actor <- format_remote_actor(object) do
      Adapter.maybe_create_remote_actor(actor)
      set_cache(actor)
    end
  end


  @doc """
  Fetches a local actor given its preferred username.
  """
  def get_by_username(username) do
    with {:ok, actor} <- Adapter.get_actor_by_username(username) do
      {:ok, actor}
    else
      _e -> {:error, "not found"}
    end
  end

  def get_by_local_id(id) when not is_nil(id) do
    with {:ok, actor} <- Adapter.get_actor_by_id(id) do
      {:ok, actor}
    else
      _e -> {:error, "not found"}
    end
  end

  @doc """
  Fetches an actor given its AP ID.

  Remote actors are first checked if they exist in database and are fetched remotely if they don't.

  Remote actors are also automatically updated every 24 hours.
  """
  @spec get_by_ap_id(String.t()) :: {:ok, Actor.t()} | {:error, any()}
  def get_by_ap_id(ap_id) do
    host = URI.parse(ap_id).host
    instance_host = URI.parse(Adapter.base_url()).host

    if host == instance_host do
      get_local_actor(ap_id)
    else
      get_remote_actor(ap_id)
    end
  end

  def get_or_fetch_by_ap_id(ap_id) do
    case get_cached_by_ap_id(ap_id) do
      {:ok, actor} -> {:ok, actor}
      _ -> fetch_by_ap_id(ap_id)
    end
  end

  def set_cache({:ok, actor}), do: set_cache(actor)
  def set_cache({:error, err}), do: {:error, err}

  def set_cache(%Actor{} = actor) do
    Cachex.put(:ap_actor_cache, "ap_id:#{actor.ap_id}", actor)
    Cachex.put(:ap_actor_cache, "username:#{actor.username}", actor)
    Cachex.put(:ap_actor_cache, "id:#{actor.id}", actor)
    {:ok, actor}
  end

  def invalidate_cache(%Actor{} = actor) do
    Cachex.del(:ap_actor_cache, "ap_id:#{actor.ap_id}")
    Cachex.del(:ap_actor_cache, "username:#{actor.username}")
    Cachex.del(:ap_actor_cache, "id:#{actor.id}")
  end

  def get_cached_by_ap_id(ap_id) do
    key = "ap_id:#{ap_id}"

    case Cachex.fetch(:ap_actor_cache, key, fn _ ->
           case get_by_ap_id(ap_id) do
             {:ok, actor} -> {:commit, actor}
             {:error, _} -> {:ignore, nil}
           end
         end) do
      {:ok, actor} -> {:ok, actor}
      {:commit, actor} -> {:ok, actor}
      {:ignore, _} -> {:error, "not found"}
    end
  end

  def get_cached_by_local_id(id) do
    key = "id:#{id}"

    case Cachex.fetch(:ap_actor_cache, key, fn _ ->
           case get_by_local_id(id) do
             {:ok, actor} ->
               {:commit, actor}

             _ ->
               {:ignore, nil}
           end
         end) do
      {:ok, actor} -> {:ok, actor}
      {:commit, actor} -> {:ok, actor}
      {:ignore, _} -> {:error, "not found"}
    end
  end

  def get_cached_by_username(username) do
    key = "username:#{username}"
    try do
      case Cachex.fetch(:ap_actor_cache, key, fn ->
            case get_by_username(username) do
              {:ok, actor} -> {:commit, actor}
              {:error, _error} -> {:ignore, nil}
            end
          end) do
        {:ok, actor} -> {:ok, actor}
        {:commit, actor} -> {:ok, actor}
        {:ignore, _} -> {:error, "not found"}
      end
    catch
      _ ->
        # workaround :nodedown errors
        get_by_username(username)
    rescue
      _ ->
        get_by_username(username)
    end
  end

  def get_cached_by_ap_id!(ap_id), do: get_by_ap_id!(ap_id)

  def get_by_ap_id!(ap_id) do
    with {:ok, actor} <- get_cached_by_ap_id(ap_id) do
      actor
    else
      {:error, _e} -> nil
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
  def set_public_key(%{data: data} = actor) do
    {:ok, entity} = Actor.ensure_keys_present(actor)
    {:ok, _, public_key} = ActivityPub.Keys.keys_from_pem(actor.keys)
    public_key = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)
    public_key = :public_key.pem_encode([public_key])

    public_key = %{
      "id" => "#{actor["id"]}#main-key",
      "owner" => entity["id"],
      "publicKeyPem" => public_key
    }

    data
    |> Map.put("publicKey", public_key)
  end

  def get_actor_from_follow(follow) do
    with {:ok, actor} <- get_cached_by_local_id(follow.creator_id) do
      actor
    else
      {:error, _} -> nil
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
    |> List.delete("https://www.w3.org/ns/activitystreams#Public")
    |> Enum.map(&get_by_ap_id!/1)
    |> Enum.filter(fn actor -> actor && !actor.local end)
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
        {:error, e} -> {:error, e}
      end
    end
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

  def update_actor_data_by_ap_id(ap_id, data) do
    ap_id
    |> Object.get_cached_by_ap_id()
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
