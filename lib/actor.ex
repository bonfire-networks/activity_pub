defmodule ActivityPub.Actor do
  @moduledoc """
  An ActivityPub Actor type and functions for dealing with actors.

  See [4. Actors](https://www.w3.org/TR/activitypub/#actors) in the
  ActivityPub specification for more information on Actors.
  """
  require Ecto.Query
  import ActivityPub.Utils
  use Arrows
  import Untangle
  # import Ecto.Query

  alias ActivityPub.Config
  require Config

  alias ActivityPub.Actor
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Federator.WebFinger
  alias ActivityPub.Object
  alias ActivityPub.Utils

  require Logger

  @typedoc """
  Your app's internal ID for an `Actor`.

  ## Examples

      "c1688a22-4e9c-42d7-935b-1f17e1d0cf58"

      "1234"
  """
  @type id :: String.t()

  @typedoc """
  The ActivityPub ID of an object, which must be a publicly-dereferencable URI,
  or `nil` if the object is anonymous.

  Note that since the URI must be publicly-dereferencable,
  you should set this value to `ActivityPub.Federator.Adapter.base_url() <> ~p"/pub/actors/\#{username}"`.
  This path is defined in `ActivityPub.Web.Endpoint` and serves data provided
  by the functions in `ActivityPub.Federator.Adapter`.

  See section [3.1 Object Identifiers](https://www.w3.org/TR/activitypub/#obj-id)
  in the ActivityPub spec for more information on the format.

  ## Examples

      "https://kenzoishii.example.com/"

      "http://localhost:4000/pub/actors/rosa"
  """
  @type ap_id :: String.t()

  @typedoc """
  An `Actor`'s user name, used as part of its ActivityPub ID.

  ## Examples

      "alyssa"

      "ben"
  """
  @type username :: String.t()

  @typedoc """
  A ULID ID (eg. using the `Needle.ULID`library) that links an `Actor` to its object in the app's database.
  """
  @type pointer_id :: String.t()

  @typedoc """
  An association (by default a `Needle.Pointer`) that references an `Actor`.

  Pointers consist of a table ID, referencing a database table,
  and a pointer ID, referencing a row in that table.
  Table and pointer IDs are both `Pointers.ULID` strings, which is UUID-like.
  """
  @type pointer :: String.t()

  @typedoc """
  An ActivityPub Actor.
  """
  @type t :: %Actor{
          id: id() | nil,
          data: map(),
          local: boolean() | nil,
          keys: binary() | nil,
          ap_id: ap_id() | nil,
          username: username() | nil,
          deactivated: boolean() | nil,
          pointer_id: pointer_id() | nil,
          pointer: pointer() | nil,
          updated_at: DateTime.t() | NaiveDateTime.t() | nil
        }

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

  defimpl Inspect do
    def inspect(%Actor{} = a, opts) do
      a
      |> Map.put(:keys, "***")
      |> Inspect.Any.inspect(opts)
    end
  end

  @doc """
  Fetches an actor given its AP ID / URI, or username@domain, or by a pointer id 

  Remote actors are just checked if they exist in AP or adapter's database and are NOT fetched remotely if they don't.

  Remote actors are also automatically updated every X hours (defaults to 24h).
  """
  @spec get(ap_id: ap_id()) :: {:ok, Actor.t()} | {:error, any()}
  def get_cached(id: id), do: do_get_cached(:id, id)

  # def get_cached(pointer: %{id: id} = pointer),
  #   do: get_cached(pointer: id) ~> Map.put(:pointer, pointer) |> ok()

  def get_cached(pointer: id), do: do_get_cached(:pointer, Utils.uid(id))
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

  defp get(username: "@" <> username), do: get(username: username)

  defp get(username: username) do
    with {:ok, actor} <- Adapter.get_actor_by_username(username) do
      {:ok, actor}
    else
      {:error, :not_found} ->
        error(username, "Adapter did not find a local actor with this username")
        {:error, :not_found}

      e ->
        error(e, "Adapter could not find a local actor with this username")
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
          {:error, :not_found} ->
            error(id, "Adapter did not find a local actor with this ID")
            {:error, :not_found}

          e ->
            error(e, "Adapter could not find a local actor with this ID")
            {:error, :not_found}
        end
    end
  end

  defp get(ap_id: "https://www.w3.org/ns/activitystreams#Public"), do: {:error, :not_an_actor}

  defp get(ap_id: id) when not is_nil(id) do
    if ActivityPub.Utils.has_as_public?(id) do
      {:error, :not_an_actor}
    else
      with {:ok, %{data: %{"type" => type}} = actor}
           when ActivityPub.Config.is_in(type, :supported_actor_types) or type == "Tombstone" <-
             ActivityPub.Object.get_cached(ap_id: id) do
        {:ok, format_remote_actor(actor)}
      else
        other ->
          warn(
            other,
            "Could not find a valid actor Object, will check with the Adapter in case it's an uncached local actor"
          )

          with {:ok, actor} <- Adapter.get_actor_by_ap_id(id) do
            {:ok, actor}
          else
            {:error, :not_found} ->
              warn(id, "Adapter did not return an actor, must not be local")
              {:error, :not_found}

            e ->
              error(e, "Adapter did not return an actor")
              {:error, :not_found}
          end
      end
    end
  end

  defp get(%{data: %{"id" => ap_id}}) when is_binary(ap_id), do: get(ap_id: ap_id)
  defp get(%{"id" => ap_id}) when is_binary(ap_id), do: get(ap_id: ap_id)
  defp get(ap_id: ap_id), do: get(ap_id)

  defp get(opts) do
    error(opts, "Unexpected args")
    # raise "Unexpected args when attempting to get an actor"
  end

  def get_non_cached(opts) do
    get(opts)
  end

  @doc """
  Tries to get a local or cache actor, or fetches it given its AP ID / URI, or username@domain, or by a pointer id.

  Remote actors are first checked if they exist in in AP or adapter's database and ARE fetched remotely if they don't.

  Remote actors are also automatically updated every X hours (defaults to 24h).
  """
  def get_cached_or_fetch(filters, opts \\ [])

  def get_cached_or_fetch([ap_id: ap_id], opts) when is_binary(ap_id) do
    with {:ok, actor} <- get_cached(ap_id: ap_id) do
      {:ok, actor}
    else
      e ->
        debug(e, "not a cached actor")

        # case get_remote_actor(ap_id) |> debug() do
        #   {:ok, actor} ->
        #     {:ok, actor}

        #   other ->
        #     debug(ap_id, "not an known local or remote actor, try fetching")

        Fetcher.fetch_fresh_object_from_id(ap_id, opts)
        |> debug("fresh actor fetched")

        # end
    end
  end

  def get_cached_or_fetch([username: "@" <> username], opts),
    do: get_cached_or_fetch([username: username], opts)

  def get_cached_or_fetch([username: username], opts) do
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

  # fallbacks
  def get_cached_or_fetch(username_or_uri, opts) when is_binary(username_or_uri) do
    if String.starts_with?(username_or_uri, "http"),
      do: get_cached_or_fetch([ap_id: username_or_uri], opts),
      else: get_cached_or_fetch([username: username_or_uri], opts)
  end

  def get_cached_or_fetch([username: other], opts), do: get_cached_or_fetch(other, opts)
  def get_cached_or_fetch([ap_id: other], opts), do: get_cached_or_fetch(other, opts)

  def get_cached_or_fetch(%{data: %{"id" => ap_id}}, opts) when is_binary(ap_id),
    do: get_cached_or_fetch([ap_id: ap_id], opts)

  def get_cached_or_fetch(%{"id" => ap_id}, opts) when is_binary(ap_id),
    do: get_cached_or_fetch([ap_id: ap_id], opts)

  def get_cached_or_fetch(%{data: %{"preferredUsername" => username}}, opts)
      when is_binary(username),
      do: get_cached_or_fetch([username: username], opts)

  def get_cached_or_fetch(%{"preferredUsername" => username}, opts) when is_binary(username),
    do: get_cached_or_fetch([username: username], opts)

  def get_cached_or_fetch(%Actor{data: _} = actor, _opts), do: {:ok, actor}

  # TODO?
  # def get_remote_actor(ap_id, maybe_create \\ true) do
  #   # raise "STOOOP"

  #   with {:ok, %{data: %{"type" => type}} = actor_object}
  #        when ActivityPub.Config.is_in(type, :supported_actor_types) or type == "Tombstone" <-
  #          Object.get_cached(ap_id: ap_id) |> debug("gct"),
  #        false <- check_if_time_to_update(actor_object),
  #        actor <- format_remote_actor(actor_object),
  #        {:ok, adapter_actor} <-
  #          if(maybe_create and type != "Tombstone",
  #            do: Adapter.maybe_create_remote_actor(actor),
  #            else: {:ok, nil}
  #          ),
  #        actor <- Map.put(actor, :pointer, adapter_actor) do
  #     {:ok, actor}
  #   else
  #     true ->
  #       update_actor(ap_id)

  #     {:error, :not_found} ->
  #       if maybe_create, do: update_actor(ap_id), else: {:error, :not_found}

  #     nil ->
  #       error(ap_id, "Remote actor not found")

  #     {:ok, actor} ->
  #       {:ok, actor}

  #     %Actor{} = actor ->
  #       {:ok, actor}

  #     {:error, e} ->
  #       {:error, e}
  #   end
  # end

  @doc """
  Fetches a remote actor by username in `username@domain.tld` format
  """
  def fetch_by_username(username, opts \\ [])
  def fetch_by_username("@" <> username, opts), do: fetch_by_username(username, opts)

  def fetch_by_username(username, opts) do
    with federating? when federating? != false <- Config.federating?(),
         {:ok, %{"id" => ap_id}} when not is_nil(ap_id) <-
           WebFinger.finger(username) do
      Fetcher.fetch_object_from_id(ap_id, opts)
    else
      {:error, e} when is_binary(e) ->
        e

      false ->
        {:error, "Federation is disabled"}

      e ->
        msg = "No AP id in WebFinger"
        error(e, msg)
        {:error, msg}
    end
  end

  @doc """
  Updates an existing actor struct by its AP ID.
  """

  # def update_actor(actor_id) when is_binary(actor_id) do
  #   debug(actor_id, "Updating actor")
  #   with {:ok, data} <- Fetcher.fetch_remote_object_from_id(actor_id) |> debug() do
  #     update_actor(actor_id, data)
  #   end
  # end

  def update_actor(actor_id, data, fetch_remote? \\ nil)

  def update_actor(actor_id, %{data: data}, fetch_remote?),
    do: update_actor(actor_id, data, fetch_remote?)

  def update_actor(actor_id, %{"id" => ap_id, "type" => "Tombstone"} = data, _fetch_remote?) do
    debug(actor_id, "Making tombstone for actor")

    with {:ok, _object} <-
           save_actor_tombstone(
             %Actor{data: data, local: nil, ap_id: ap_id},
             Map.drop(data, ["@context"])
           ),
         {:ok, actor} <- get(ap_id: actor_id) do
      set_cache(actor)
    end
  end

  def update_actor(actor_id, data, fetch_remote?) do
    with {:ok, object} <- update_actor_data(actor_id, data, fetch_remote?),
         Adapter.update_remote_actor(object),
         {:ok, actor} <- get(ap_id: actor_id) do
      set_cache(actor)
    else
      {:no_update, object} ->
        debug("there was no update, so we skip updating the adapter or cache")
        {:ok, object}

      other ->
        other
    end
  end

  # defp check_if_time_to_update(actor) do
  #   (NaiveDateTime.diff(NaiveDateTime.utc_now(Calendar.ISO), actor.updated_at) >= 86_400)
  #   |> info("Time to update the actor?")
  # end

  # defp username_from_ap_id(ap_id) do
  #   ap_id
  #   |> String.split("/")
  #   |> List.last()
  # end

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

  def create_or_update_actor_from_object(actor, opts \\ []) do
    case do_maybe_create_or_update_actor_from_object(actor, opts) do
      {:ok, %Actor{} = actor} ->
        debug("Actor created or updated")
        {:ok, actor}

      {:ok, %{} = object} ->
        warn(object, "Not an actor?")
        {:ok, object}

      e ->
        error(e, "Could not find or create an actor")
    end
  end

  defp do_maybe_create_or_update_actor_from_object(%{"type" => type} = data, opts)
       when ActivityPub.Config.is_in(type, :supported_actor_types) do
    debug("create from AP JSON data")

    case create_or_update_ap_object_for_actor(data, opts[:already_fetched]) do
      {:ok, %Object{} = object} ->
        debug("created object, now try actor")
        do_maybe_create_or_update_actor_from_object(object, opts)

      {:ok, %Actor{} = actor} ->
        {:ok, actor}

      other ->
        other
        |> warn("unexpected")
    end
  end

  defp do_maybe_create_or_update_actor_from_object(%{data: %{"type" => type}} = actor, opts)
       when ActivityPub.Config.is_in(type, :supported_actor_types) do
    debug("create actor from AP Object")

    with actor <- format_remote_actor(actor),
         {:ok, actor} <- set_cache(actor),
         {:ok, adapter_actor} <- Adapter.maybe_create_remote_actor(actor),
         {:ok, actor} <- set_cache(actor) do
      {:ok, actor |> Map.put(:pointer, adapter_actor)}
    end
  end

  # defp do_maybe_create_or_update_actor_from_object(ap_id) when is_binary(ap_id) do
  #   with {:ok, object} <- Fetcher.fetch_fresh_object_from_id(ap_id) |> info() do
  #     do_maybe_create_or_update_actor_from_object(object)
  #   end
  # end
  defp do_maybe_create_or_update_actor_from_object({:ok, object}, opts),
    do: do_maybe_create_or_update_actor_from_object(object, opts)

  defp do_maybe_create_or_update_actor_from_object(object, _opts),
    do: error(object, "Actor to update not recognised")

  defp create_or_update_ap_object_for_actor(%{"id" => id} = data, true = _already_fetched) do
    with {:error, :not_found} <- Object.get_cached(ap_id: id),
         #  don't have to do manually since it gets processed after fetch?
         {:ok, object} <- Object.prepare_data(data),
         {:ok, object} <- Object.do_insert(object) do
      {:ok, object}
    else
      {:ok, _cached_data} ->
        debug("Object already exists, update it and Actor based on it")
        update_actor(id, data, false)

      {:error, %Ecto.Changeset{errors: [_data____id: {"has already been taken", _}]}} ->
        info(id, "Entry already exists, update Actor based on it")
        update_actor(id, data, false)

      other ->
        error(other, "Unexpected")
    end
  end

  defp create_or_update_ap_object_for_actor(
         %{"id" => id} = _ignore_passed_data_for_safety,
         _false
       ) do
    debug("re-fetch Actor from source for safety")
    Fetcher.fetch_fresh_object_from_id(id, [])
  end

  def set_cache({:ok, actor}), do: set_cache(actor)

  def set_cache(%Actor{} = actor) do
    for {key, value} <-
          ([
             {:id, actor.id},
             {:ap_id, actor.ap_id},
             {:username, actor.username}
           ] ++
             (case actor.pointer_id || Map.get(actor.pointer || %{}, :id) do
                nil -> []
                _ -> [{:pointer, actor.pointer_id}]
              end))
          |> debug("keys") do
      Cachex.put(:ap_actor_cache, Utils.ap_cache_key(key, value), actor)
    end

    {:ok, actor}
  end

  def set_cache(%{data: %{"type" => type}} = actor)
      when ActivityPub.Config.is_in(type, :supported_actor_types) do
    format_remote_actor(actor)
    |> set_cache()
  end

  def set_cache(e), do: error(e, "Not an actor")

  def invalidate_cache(%Actor{} = actor) do
    Cachex.del(:ap_actor_cache, Utils.ap_cache_key(:id, actor.id))
    Cachex.del(:ap_actor_cache, Utils.ap_cache_key(:ap_id, actor.ap_id))

    Cachex.del(
      :ap_actor_cache,
      Utils.ap_cache_key(:pointer, actor.pointer_id || Map.get(actor.pointer || %{}, :id))
    )

    Cachex.del(:ap_actor_cache, Utils.ap_cache_key(:username, actor.username))

    Cachex.del(:ap_actor_cache, Utils.ap_cache_key(:json, actor.username))
    Object.invalidate_cache(actor)
  end

  def get_followings(actor, purpose_or_current_actor \\ nil) do
    followings =
      Adapter.get_following_local_ids(actor, purpose_or_current_actor)
      |> debug("following_local_ids")
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&get_cached!(pointer: &1))
      |> Enum.reject(&is_nil/1)
      |> debug("got_followings")

    {:ok, followings}
  end

  def get_followers(actor, purpose_or_current_actor \\ nil) do
    Adapter.get_follower_local_ids(actor, purpose_or_current_actor)
    |> debug("follower_local_ids")
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&get_cached!(pointer: &1))
    |> Enum.reject(&is_nil/1)
    |> debug("got_followers")
  end

  def get_external_followers(actor, purpose_or_current_actor \\ nil) do
    get_followers(actor, purpose_or_current_actor)
    # Filter locals
    |> Enum.filter(fn x -> !x.local end)
  end

  def delete(actor, is_local?)

  def delete(%Actor{id: _id} = actor, true) do
    # only add a tombstone for local actors

    ret =
      swap_or_create_actor_tombstone(actor)

    # |> debug("tombstoned")

    invalidate_cache(actor)

    ret

    # if Utils.is_uid?(id) do
    #   with {:ok, object} <- Object.get_cached(pointer: id) do
    #     Object.hard_delete(object)
    #   else
    #     other ->
    #       error(other)
    #       {:ok, :not_deleted}
    #   end
    # else
    #   repo().delete(%Object{
    #     id: id
    #   })
    # end
  end

  def delete(%Actor{ap_id: ap_id} = actor, false) do
    with {:ok, object} <- Object.get_cached(ap_id: ap_id) do
      ret = Object.hard_delete(object)
      invalidate_cache(actor)
      ret
    else
      other ->
        error(other)
        {:ok, :not_deleted}
    end
  end

  def swap_or_create_actor_tombstone(%Actor{} = actor) do
    actor =
      actor
      |> debug()
      |> Keys.add_public_key(false)

    tombstone =
      Object.make_tombstone(actor)
      |> Map.merge(Map.take(actor.data, ["publicKey", "preferredUsername"]))
      |> Map.put("preferredUsername", actor.username)
      |> debug()

    save_actor_tombstone(actor, tombstone)
  end

  def save_actor_tombstone(%Actor{} = actor, tombstone) do
    case update_actor_data(actor, tombstone, false) do
      {:ok, del} ->
        {:ok, del}

      {:no_update, del} ->
        error("Could not update the actor")

      e ->
        debug(e, "no such actor in AP db, create a tombstone instead")

        insert_actor_tombstone(actor, tombstone)
    end
  end

  defp insert_actor_tombstone(%Actor{} = actor, tombstone) do
    %{
      id: Ecto.UUID.generate(),
      pointer_id: actor.pointer_id,
      data: tombstone,
      public: true,
      local: actor.local,
      is_object: true
    }
    # |> debug()
    |> Object.changeset()
    # |> debug()
    |> repo().insert()
  rescue
    e in Ecto.ConstraintError ->
      error(e, "seems pointer may no longer exist, try without")

      %{
        id: Ecto.UUID.generate(),
        data: tombstone,
        public: true,
        local: actor.local,
        is_object: true
      }
      |> Object.changeset()
      |> repo().insert()
  end

  defp update_actor_data(actor, data, fetch_remote? \\ true)

  defp update_actor_data(%{ap_id: ap_id}, data, fetch_remote?) when is_binary(ap_id) do
    update_actor_data(ap_id, data, fetch_remote?)
  end

  defp update_actor_data(%{"actor" => ap_id}, data, fetch_remote?) when is_binary(ap_id) do
    update_actor_data(ap_id, data, fetch_remote?)
  end

  defp update_actor_data(%{"id" => ap_id}, data, fetch_remote?) when is_binary(ap_id) do
    update_actor_data(ap_id, data, fetch_remote?)
  end

  defp update_actor_data(ap_id, update_data, fetch_remote?) when is_binary(ap_id) do
    with {:ok, %{data: existing_data} = object} when existing_data != update_data <-
           Object.get_uncached(ap_id: ap_id),
         {:ok, %{data: updated_data} = object} when updated_data != existing_data <-
           maybe_update_actor_data(ap_id, object, update_data, fetch_remote?) do
      debug("updated")
      {:ok, object}
    else
      {:ok, object} ->
        {:no_update, object}

      e ->
        error(e, "Cannot update a locally-unknown actor")
    end
  end

  defp update_actor_data(%Object{} = object, %{} = data, false) do
    do_update_actor_data(object, data)
  end

  defp update_actor_data(object, _data, _) do
    error(object, "Could not find the actor to update")
  end

  defp maybe_update_actor_data(ap_id, object, data, fetch_remote?) do
    if fetch_remote? do
      debug("re-fetch remote actor before updating for safety")
      Fetcher.fetch_fresh_object_from_id(ap_id, [])
    else
      debug("insert")
      do_update_actor_data(object, data)
    end
  end

  defp do_update_actor_data(%Object{} = object, data) do
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

    update_actor_data(actor, new_data, false)
    # Return Actor
    set_cache(get(ap_id: actor.ap_id))
  end

  def reactivate(%Actor{local: false} = actor) do
    new_data =
      actor.data
      |> Map.put("deactivated", false)

    update_actor_data(actor, new_data, false)
    # Return Actor
    set_cache(get(ap_id: actor.ap_id))
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

  def actor?(%{data: data}), do: actor?(data)

  def actor?(%{"type" => type})
      when ActivityPub.Config.is_in(type, :supported_actor_types),
      do: true

  def actor?(%{"formerType" => type})
      when ActivityPub.Config.is_in(type, :supported_actor_types),
      do: true

  def actor?(_), do: false

  def also_known_as?(ap_id, %{"alsoKnownAs" => aliases} = _actor)
      when is_binary(ap_id) and is_list(aliases) and aliases != [] do
    (ap_id in aliases)
    |> debug("alsoKnownAss")
  end

  def also_known_as?(ap_id, %{data: data}), do: also_known_as?(ap_id, data)
  def also_known_as?(%{ap_id: ap_id}, data), do: also_known_as?(ap_id, data)

  def also_known_as?(ap_id, actor) do
    warn(actor, "Could not match #{ap_id} in any alsoKnownAs for this actor")
    false
  end
end

defimpl Jason.Encoder, for: ActivityPub.Actor do
  def encode(%{data: %{} = data}, opts) do
    Jason.Encode.map(data, opts)
  end
end
