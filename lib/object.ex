defmodule ActivityPub.Object do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  import Untangle
  use Arrows
  require ActivityPub.Config

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias ActivityPub.MRF
  alias ActivityPub.Queries
  import ActivityPub.Utils
  alias ActivityPub.Utils

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ap_object" do
    field(:data, :map)
    field(:local, :boolean, default: true)
    field(:public, :boolean, default: false)
    # is it an object rather than an activity?
    field(:is_object, :boolean, default: false)

    # TODO: get the table to reference from config? and maybe the type as well
    belongs_to(:pointer, Needle.Pointer, type: Needle.UID)

    # Attention: these is are fake relations, don't try to join them blindly and expect it to work!
    # The foreign keys are embedded in a jsonb field.
    # You probably want to do an inner join and a preload, as in `Queries.with_preloaded_object/2` or `Queries.with_joined_activity/3`
    has_one(:object, Object, on_delete: :nothing, foreign_key: :id)
    has_one(:activity, Object, on_delete: :nothing, foreign_key: :id)

    timestamps()
  end

  def get_cached(id: id) when is_binary(id), do: do_get_cached(:id, id)
  # def get_cached(uuid: id) when is_binary(id), do: do_get_cached(:uuid, id)
  def get_cached(ap_id: id) when is_binary(id), do: do_get_cached(:ap_id, id)
  def get_cached(pointer: id) when is_binary(id), do: do_get_cached(:pointer, Utils.uid(id))

  def get_cached(_: %Object{} = o), do: o

  def get_cached(id: %{id: id}) when is_binary(id), do: get_cached(id: id)
  def get_cached(pointer: %{id: id}) when is_binary(id), do: get_cached(pointer: id)
  def get_cached([{_, %{ap_id: ap_id}}]) when is_binary(ap_id), do: get_cached(ap_id: ap_id)
  def get_cached([{_, %{"id" => ap_id}}]) when is_binary(ap_id), do: get_cached(ap_id: ap_id)

  def get_cached([{_, %{data: %{"id" => ap_id}}}]) when is_binary(ap_id),
    do: get_cached(ap_id: ap_id)

  def get_cached(id) when is_binary(id) do
    if Utils.is_uid?(id) do
      get_cached(pointer: id)
    else
      if String.starts_with?(id, "http") do
        get_cached(ap_id: id)
      else
        get_cached(id: id)
      end
    end
  end

  # def get_cached(opts) do
  #   error(opts, "Unexpected args")
  #   raise "Unexpected args for get_cached"
  # end
  def get_cached(opts), do: get(opts)

  defp do_get_cached(key, val), do: Utils.get_with_cache(&get/1, :ap_object_cache, key, val)

  def get_cached!(opts) do
    with {:ok, object} <- get_cached(opts) do
      object
    else
      e ->
        warn(e, "No such object found")
        nil
    end
  end

  def get_uncached(opts), do: get(opts)

  defp get(id) when is_binary(id) do
    get(pointer: id)
  end

  defp get(id: id) when is_binary(id) and byte_size(id) == 26 do
    get(id)
  end

  defp get(id: id) when is_binary(id) do
    get(uuid: id)
  end

  defp get(uuid: id) when is_binary(id) do
    case repo().get(Object, id) do
      %Object{} = object -> {:ok, object}
      _ -> {:error, :not_found}
    end
  end

  defp get(pointer: id) when is_binary(id) do
    # TODO: support prefixed UUIDs?
    if Utils.is_ulid?(id) do
      case repo().get_by(Object, pointer_id: id) do
        %Object{} = object -> {:ok, object}
        _ -> {:error, :not_found}
      end
    else
      debug(id, "Expected a valid UID pointer ID, trying as UUID AP object ID instead")
      get(uuid: id)
    end
  end

  defp get(ap_id: ap_id) when is_binary(ap_id) do
    case repo().one(query(ap_id: ap_id) |> debug()) |> debug() do
      %Object{} = object -> {:ok, object}
      _ -> {:error, :not_found}
    end
  end

  defp get(ap_id: ap_id), do: get(ap_id)

  defp get(username: username) when is_binary(username) do
    case repo().one(query(username: username)) do
      %Object{} = object -> {:ok, object}
      _ -> {:error, :not_found}
    end
  end

  defp get(%{data: %{"id" => ap_id}}) when is_binary(ap_id), do: get(ap_id: ap_id)
  defp get(%{"id" => ap_id}) when is_binary(ap_id), do: get(ap_id: ap_id)

  defp get(%{id: id}) when is_binary(id) do
    get(pointer: id)
  end

  defp get(filters) when is_list(filters) do
    case repo().one(query(filters)) do
      %Object{} = object -> {:ok, object}
      _ -> {:error, :not_found}
    end
  end

  defp get(nil) do
    raise "Cannot get an AP object without an ID"
  end

  defp get(opts) do
    err(opts, "Unexpected args when attempting to get an AP object")
  end

  def query(ap_id: ap_id) when is_binary(ap_id) do
    from(object in Object,
      # support for looking up by non-canonical URL as well
      # use MD5 hash for URL comparison to leverage the hash index
      where:
        fragment("(?)->>'id' = ?", object.data, ^ap_id) or
          fragment("md5(?->>'url') = md5(?)", object.data, ^ap_id)
    )
  end

  def query(username: username) when is_binary(username) do
    from(object in Object,
      # support for looking up by non-canonical URL
      where: fragment("(?)->>'preferredUsername' = ?", object.data, ^username)
    )
  end

  def query(username: username, local: local?) when is_binary(username) do
    from(object in Object,
      # support for looking up by non-canonical URL
      where:
        object.local == ^local? and
          fragment("(?)->>'preferredUsername' = ?", object.data, ^username)
    )
  end

  def query(opts) do
    err(opts, "Unexpected args when attempting to query an AP object")
  end

  def get_activity_for_object_ap_id(ap_id, verb \\ "Create")

  def get_activity_for_object_ap_id(%{"id" => ap_id}, verb) when is_binary(ap_id),
    do: get_activity_for_object_ap_id(ap_id, verb)

  def get_activity_for_object_ap_id(ap_id, verb) when is_binary(ap_id) do
    Queries.activity_by_object_ap_id(ap_id, verb)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> repo().one()
  end

  def get_activity_for_object_ap_id(ap_id, _verb) do
    error(ap_id, "object has no ID")
    nil
  end

  @doc false
  def insert(params, local?, pointer \\ nil, opts \\ [])
      when is_map(params) and is_boolean(local?) do
    with activity_id <- Ecto.UUID.generate(),
         params <- normalize_params(params, activity_id, pointer),
         :ok <- Actor.check_actor_is_active(params["actor"]),
         # set some healthy boundaries
         {:ok, params} <- MRF.filter(params, opts |> Keyword.put(:is_local, local?)),
         # first insert the object if there is one
         {:ok, activity, object} <-
           do_insert_object(params, local?, pointer, opts[:upsert] || false),
         # then insert the activity (containing only an ID as object)
         {:ok, activity} <-
           (if not is_nil(activity) do
              if is_nil(object) do
                # insert activity even without an object
                do_insert(%{
                  id: activity_id,
                  data: activity,
                  local: local?,
                  public: Utils.public?(activity),
                  pointer_id: Utils.uid(pointer)
                })
              else
                # insert activity (with the object ID as object)
                do_insert(%{
                  id: activity_id,
                  data: activity,
                  local: local?,
                  public: Utils.public?(activity, object)
                })
              end
            else
              {:ok, nil}
            end) do
      # Splice in the child object if we have one.
      activity =
        if not is_nil(activity) and not is_nil(object) do
          Map.put(activity, :object, object)
        else
          activity || object
        end

      debug(activity, "inserted activity in #{repo()}")

      {:ok, activity}
    else
      %Object{} = object ->
        error("error while trying to insert, return the object instead")
        {:ok, object}

      {:reject, e} when is_binary(e) ->
        error(e)
        {:reject, e}

      {:reject, e} ->
        warn(e, "Cannot federate due to local boundaries and filters")
        {:reject, e}

      :ignore ->
        info(params, "Do not federate due to local boundaries and filters")
        # {:ignore, "Do not federate due to local boundaries and filters"}
        :ignore

      {:error,
       %Ecto.Changeset{
         errors: [
           _data____id: {_, [constraint: :unique, constraint_name: "ap_object__data____id_index"]}
         ]
       } = e} ->
        debug(e, "Already exists, try fetching from cache")
        Object.get_cached(ap_id: params["id"])

      error ->
        debug(params, "Error while trying to insert these params")
        err(error, "Error while trying to save the object for federation on repo #{repo()}")
        {:error, "Error while trying to save the object for federation"}
    end
  end

  @doc """
  Inserts a full object if it is contained in an activity.
  """
  defp do_insert_object(
         activity,
         local \\ false,
         pointer \\ nil,
         upsert? \\ false
       )

  defp do_insert_object(
         %{"object" => %{"type" => type} = object_data} = activity,
         local,
         pointer,
         upsert?
       )
       when ActivityPub.Config.is_in(type, :supported_actor_types) == false and
              ActivityPub.Config.is_in(type, :supported_activity_types) == false do
    # we're taking a shortcut by assuming that any object that isn't a known actor or activity type is an object (which seems a bit better than only supporting a known list of object types)

    with {:ok, object} <-
           actually_do_insert_object(activity, object_data, local, pointer, upsert?) do
      # return an activity that contains the ID as object rather than the actual object
      {:ok, Map.put(activity, "object", object.data["id"]), object}
    end
  end

  defp do_insert_object(
         %{"type" => type} = intransitive_object,
         local,
         pointer,
         upsert?
       )
       when ActivityPub.Config.is_in(type, :supported_intransitive_types) == true do
    # we're taking a shortcut by assuming that any object that isn't a known actor or activity type is an object (which seems a bit better than only supporting a known list of object types)

    with {:ok, object} <-
           actually_do_insert_object(nil, intransitive_object, local, pointer, upsert?) do
      # return an activity that contains the ID as object rather than the actual object
      {:ok, nil, object}
    end
  end

  # there's no object
  defp do_insert_object(activity, _local, _pointer, _), do: {:ok, activity, nil}

  defp actually_do_insert_object(
         activity,
         object_data,
         local,
         pointer,
         upsert?
       ) do
    # we're taking a shortcut by assuming that any object that isn't a known actor or activity type is an object (which seems a bit better than only supporting a known list of object types)
    debug(object_data, "object to '#{if upsert?, do: "update", else: "insert"}'")

    with maybe_existing_object <-
           normalize(object_data, false, pointer) |> debug("maybe_existing_object"),
         # first check if it already exists
         {:ok, object_params} <- prepare_data(object_data, local, pointer, activity),
         {:ok, object} <-
           maybe_upsert(upsert?, maybe_existing_object, object_params) |> info("maybe_upserted") do
      # return an activity that contains the ID as object rather than the actual object
      {:ok, object}
    end
  end

  # there's no object
  defp actually_do_insert_object(activity, _local, _pointer, _), do: {:ok, activity, nil}

  def do_insert(attrs) do
    attrs
    |> changeset()
    |> repo().insert()
  end

  def maybe_upsert(:update, %ActivityPub.Object{} = existing_object, attrs) do
    debug(existing_object, "Object to update")

    update_changeset(existing_object, attrs)
    |> debug("to upsert")
    |> update_and_set_cache()
  end

  def maybe_upsert(true, %ActivityPub.Object{} = existing_object, attrs) do
    debug(existing_object, "Object to upsert")
    debug(attrs, "attrs to upsert")

    changeset(existing_object, attrs)
    |> update_and_set_cache()
  end

  def maybe_upsert(_, %ActivityPub.Object{} = existing_object, _attrs) do
    warn("Will not insert an object that already exists")
    debug(existing_object)
    {:ok, existing_object}
  end

  def maybe_upsert(_, _, attrs) do
    debug("Insert")
    do_insert(attrs)
  end

  def set_cache(%{id: id, data: %{"id" => ap_id}, pointer_id: pointer_id} = object) do
    debug(ap_id, "put_cache")

    # TODO: store in cache only once, and only IDs for the others
    Cachex.put(:ap_object_cache, Utils.ap_cache_key(:id, id), object)
    Cachex.put(:ap_object_cache, Utils.ap_cache_key(:ap_id, ap_id), object)

    if pointer_id = pointer_id || Map.get(object.pointer || %{}, :id) do
      Cachex.put(:ap_object_cache, Utils.ap_cache_key(:pointer, pointer_id), object)
    end

    {:ok, object}
  end

  def invalidate_cache(%{
        id: id,
        data: %{"id" => ap_id},
        pointer_id: pointer_id,
        pointer: pointer
      }) do
    debug(ap_id, "invalidate_cache")

    Cachex.del(:ap_object_cache, Utils.ap_cache_key(:id, id))
    Cachex.del(:ap_object_cache, Utils.ap_cache_key(:ap_id, ap_id))

    Cachex.del(:ap_object_cache, Utils.ap_cache_key(:json, id))

    if pointer_id = pointer_id || Map.get(pointer || %{}, :id) do
      Cachex.del(:ap_object_cache, Utils.ap_cache_key(:pointer, pointer_id))
      Cachex.del(:ap_object_cache, Utils.ap_cache_key(:json, pointer_id))
    end

    :ok
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
  end

  def changeset(object, attrs) do
    object
    |> cast(attrs, [:id, :data, :local, :public, :pointer_id, :is_object])
    |> common_changeset()
  end

  def update_changeset(object, attrs) do
    object
    |> cast(attrs, [:data])
    |> common_changeset()
  end

  def common_changeset(object) do
    object
    |> validate_required(:data)
    |> unique_constraint(:pointer_id)
    |> unique_constraint(:_data____id, match: :exact)
  end

  def update_existing(object_id, attrs) do
    case get(id: object_id) do
      {:ok, object} ->
        do_update_existing(object, attrs)

      _e ->
        error(object_id, "Could not find the object to update")
    end
  end

  def do_update_existing(%ActivityPub.Object{} = object, attrs) do
    debug(attrs)

    object
    |> debug("update")
    |> change(attrs)
    |> debug("cs")
    |> update_and_set_cache()
  end

  def update_and_set_cache(changeset) do
    with {:ok, object} <- repo().update(changeset) do
      set_cache(object)
    else
      e -> error(e, "Could not update the AP object")
    end
  rescue
    e in Ecto.ConstraintError ->
      error(e, "Could not update the AP object")
  end

  @doc """
  Updates a follow activity's state (for locked accounts).
  """
  def update_state(
        %Object{data: %{"actor" => actor, "object" => object}} = activity,
        type,
        state
      ) do
    Queries.by_type(type)
    |> Queries.by_actor(actor)
    |> Queries.by_object_id(object)
    # |> where(fragment("data->>'state' = 'pending'") or fragment("data->>'state' = 'accept'"))
    |> update(set: [data: fragment("jsonb_set(data, '{state}', ?)", ^state)])
    |> repo().update_all([])

    with {:ok, activity} <- get(id: activity.id) do
      set_cache(activity)
      |> debug()

      {:ok, activity}
    end
  end

  # for debugging
  @doc false
  def all() do
    repo().many(from(object in Object))
  end

  def all(filters) do
    repo().many(query(filters))
  end

  @doc """
  Prepares a struct to be inserted into the objects table
  """
  def prepare_data(data, local \\ false, pointer \\ nil, associated_activity \\ nil) do
    data =
      %{}
      |> Map.put(:data, data)
      |> Map.put(:local, local)
      |> Map.put(:public, Utils.public?(associated_activity, data))
      |> Map.put(:pointer_id, pointer)
      |> Map.put(:is_object, associated_activity != nil)

    {:ok, data}
  end

  defp lazy_put_activity_defaults(map, activity_id, pointer) do
    map =
      map
      # |> debug()
      |> Map.put_new_lazy("id", fn -> map["url"] || object_url(activity_id) end)
      |> Map.put_new_lazy("published", &Utils.make_date/0)

    # |> Map.put_new_lazy("context", &Utils.generate_id("contexts"))

    if is_map(map["object"]) do
      object =
        map["object"]
        |> lazy_put_object_defaults(map["id"], pointer, map["context"])
        |> normalize_actors()

      %{map | "object" => object}
    else
      map
    end
    |> debug
  end

  defp lazy_put_object_defaults(%{data: data}, activity_id, pointer, context),
    do: lazy_put_object_defaults(data, activity_id, pointer, context)

  defp lazy_put_object_defaults(map, _activity_id, pointer, context) do
    map
    |> Map.put_new_lazy("id", fn ->
      map["url"] ||
        object_url(pointer)
    end)
    |> Map.put_new_lazy("published", &Utils.make_date/0)
    |> Utils.maybe_put("context", context)
    |> debug
  end

  def normalize(_, fetch_remote? \\ true, pointer \\ nil)

  def normalize(object, opts, pointer) when is_list(opts),
    do: normalize(object, opts[:fetch] || opts[:fetch_remote?], pointer || opts[:pointer])

  def normalize({:ok, object}, fetch_remote?, pointer),
    do: normalize(object, fetch_remote?, pointer)

  def normalize(%{__struct__: Object, data: %{"object" => object}}, fetch_remote?, pointer),
    do: normalize(object, fetch_remote?, pointer)

  def normalize(%{__struct__: Object} = object, _, _), do: object

  def normalize(%{"id" => ap_id} = _object, true, pointer)
      when is_binary(ap_id) do
    # if(length(Map.keys(object))==1) do # we only have an ID
    normalize(ap_id, true, pointer)
    # else
    #   %{data: object}
    # end
  end

  def normalize(ap_id, fetch_remote?, pointer) when is_binary(ap_id) and is_binary(pointer),
    do:
      get_cached!(pointer: pointer) || get_cached!(ap_id: ap_id) ||
        maybe_fetch(ap_id, fetch_remote?)

  def normalize(_, _fetch_remote?, pointer) when is_binary(pointer),
    do: get_cached!(pointer: pointer)

  def normalize(ap_id, fetch_remote?, _) when is_binary(ap_id),
    do: get_cached!(ap_id: ap_id) || maybe_fetch(ap_id, fetch_remote?)

  def normalize(%{"id" => ap_id} = _data, false, pointer)
      when is_binary(ap_id) do
    normalize(ap_id, false, pointer) || nil
  end

  def normalize(_, _, _), do: nil

  defp maybe_fetch(ap_id, true) when is_binary(ap_id) do
    with {:ok, object} <- Fetcher.fetch_object_from_id(ap_id, triggered_by: "Object.normalize") do
      object
    else
      e ->
        error(e)
        nil
    end
  end

  defp maybe_fetch(_, _), do: nil

  def get_ap_id(%{"id" => id} = _), do: id
  def get_ap_id(%{data: data}), do: get_ap_id(data)
  def get_ap_id(id) when is_binary(id), do: id
  def get_ap_id(_), do: nil

  defp get_ap_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&get_ap_id/1)
  end

  def actor_from_data(%{"actor" => actor}) when not is_nil(actor) and actor != [],
    do: actor_from_data(actor)

  def actor_from_data(%{"attributedTo" => actor}) when not is_nil(actor) and actor != [],
    do: actor_from_data(actor)

  def actor_from_data(%{"id" => _, "type" => type} = actor)
      when ActivityPub.Config.is_in(type, :supported_actor_types),
      do: actor

  def actor_from_data(actors) when is_list(actors) do
    Enum.map(actors, &actor_from_data/1)
    |> Enum.reject(&is_nil/1)
    |> List.first()

    # ignores any secondary actors
  end

  def actor_from_data(%{data: data}), do: actor_from_data(data)

  def actor_from_data(e) when is_binary(e) do
    debug(e, "We got a string, just assume that's the actor...")
    e
  end

  def actor_from_data(e) do
    error(e, "No actor found")
  end

  def actor_id_from_data(id) when is_binary(id) do
    id
  end

  def actor_id_from_data(data) do
    case actor_from_data(data) do
      %{"id" => id} ->
        id

      id when is_binary(id) ->
        id

      e ->
        warn(e, "No actor ID found")
        nil
    end
  end

  def normalize_params(params, activity_id \\ nil, pointer \\ nil)

  def normalize_params(%{data: data} = _params, activity_id, pointer) do
    normalize_params(data, activity_id, pointer)
  end

  def normalize_params(params, activity_id, pointer) do
    normalize_actors(params)
    |> lazy_put_activity_defaults(activity_id, pointer)
  end

  def normalize_actors(%{data: data}), do: normalize_actors(data)

  def normalize_actors(params) do
    # Some implementations include actors as URIs, others inline the entire actor object, this function figures out what the URIs are based on what we have.
    params
    |> Utils.maybe_put("actor", get_ap_id(params["actor"]))
    |> normalise_tos()

    # |> Utils.maybe_put("to", get_ap_ids(params["to"]))
    # |> Utils.maybe_put("bto", get_ap_ids(params["bto"]))
    # |> Utils.maybe_put("cc", get_ap_ids(params["cc"]))
    # |> Utils.maybe_put("bcc", get_ap_ids(params["bcc"]))
    # |> Utils.maybe_put("audience", get_ap_ids(params["audience"]))
  end

  def normalise_tos(object) do
    object
    |> normalise_to()
    |> normalise_addressing_field("cc")
    |> normalise_addressing_field("bto")
    |> normalise_addressing_field("bcc")
  end

  defp normalise_to(map) do
    extra = if Utils.public?(map), do: [ActivityPub.Config.public_uri()], else: []
    debug(extra)
    normalise_addressing_field(map, "to", extra)
  end

  defp normalise_addressing_field(map, field, extra \\ []) do
    addrs = Map.get(map, field)

    cond do
      is_list(addrs) ->
        Enum.filter(addrs, &is_binary/1)

      is_binary(addrs) ->
        [addrs]

      true ->
        []
    end
    |> Enum.reject(&(&1 in ["as:Public", "Public"]))
    |> Kernel.++(extra)
    |> Enum.uniq()
    |> Utils.maybe_put(map, field, ...)
  end

  def make_tombstone(
        %{data: %{"id" => id, "type" => type} = _data},
        deleted \\ DateTime.utc_now()
      ) do
    %{
      "id" => id,
      "formerType" => type,
      "deleted" => deleted,
      "type" => "Tombstone"
    }
  end

  def is_deleted?(%{data: data}), do: is_deleted?(data)

  def is_deleted?(data) do
    case data do
      %{"suspended" => true} -> true
      %{"type" => "Tombstone"} -> true
      %{"type" => "Delete"} -> true
      %{"object" => %{"type" => "Tombstone"}} -> true
      nil -> true
      _ -> false
    end
  end

  def swap_object_with_tombstone(object) do
    tombstone = make_tombstone(object)

    object
    |> changeset(%{data: tombstone})
    |> repo().update()
  end

  def delete(%{} = object) do
    with {:ok, tombstone} <- swap_object_with_tombstone(object),
         :ok <- invalidate_cache(object) do
      {:ok, tombstone}
    end
  end

  def hard_delete(%Object{} = object) do
    with :ok <- invalidate_cache(object) do
      repo().delete(object)
    end
  end

  # TODO: move queries in Queries module

  def get_outbox_for_actor(ap_id, page \\ 1)
  def get_outbox_for_actor(%{ap_id: ap_id}, page), do: get_outbox_for_actor(ap_id, page)
  def get_outbox_for_actor(%{"id" => ap_id}, page), do: get_outbox_for_actor(ap_id, page)

  def get_outbox_for_actor(ap_id, page) when is_binary(ap_id) do
    now = DateTime.utc_now()

    from(object in Object,
      where:
        object.public == true and
          object.is_object != true and
          (fragment("(?->>'published') IS NULL", object.data) or
             fragment("COALESCE((?->>'published')::timestamptz, ?) <= ?", object.data, ^now, ^now))
    )
    |> Queries.by_actor(ap_id)
    |> do_list_page(page)
  end

  def get_outbox_for_instance(page \\ 1) do
    now = DateTime.utc_now()

    from(object in Object,
      where:
        object.local == true and
          object.public == true and
          object.is_object != true and
          (fragment("(?->>'published') IS NULL", object.data) or
             fragment("COALESCE((?->>'published')::timestamptz, ?) <= ?", object.data, ^now, ^now))
    )
    |> do_list_page(page)
  end

  def get_inbox_for_instance(page \\ 1) do
    now = DateTime.utc_now()

    from(object in Object,
      where:
        object.local == false and
          object.public == true and
          object.is_object != true and
          (fragment("(?->>'published') IS NULL", object.data) or
             fragment("COALESCE((?->>'published')::timestamptz, ?) <= ?", object.data, ^now, ^now))
    )
    |> do_list_page(page)
  end

  def get_inbox_for_actor(ap_id, page \\ 1)
  def get_inbox_for_actor(%{ap_id: ap_id}, page), do: get_inbox_for_actor(ap_id, page)
  def get_inbox_for_actor(%{"id" => ap_id}, page), do: get_inbox_for_actor(ap_id, page)

  def get_inbox_for_actor(ap_id, page) when is_binary(ap_id) do
    from(object in Object,
      where: object.is_object != true,
      where:
        (fragment("(?->'to')::jsonb \\? ?", object.data, ^ap_id) or
           fragment("(?->'cc')::jsonb \\? ?", object.data, ^ap_id)) and
          fragment("(data->>'published')::timestamptz <= now()")
    )
    |> do_list_page(page)
  end

  def get_inbox_for_actor(_, _page), do: []

  # def get_inbox(instance_or_actor_url, page) do
  #   instance_or_actor_filter = "#{instance_or_actor_url}%"

  #   from(object in Object,
  #     where:
  #       fragment("(?)->>'actor' ilike ?", object.data, ^instance_or_actor_filter) and
  #         object.local != true and
  #         object.public == true and
  #         object.is_object != true
  #   )
  #   |> do_list_page(page)
  # end

  defp do_list_page(query, page) do
    offset = (page - 1) * 10

    query
    |> Queries.ordered()
    |> limit(10)
    |> offset(^offset)
    |> Queries.with_preloaded_object()
    |> repo().all()
  end

  def object_url(%{pointer_id: id}) when is_binary(id), do: object_url(id)
  def object_url(%{id: id}) when is_binary(id), do: object_url(id)
  def object_url(%{pointer: %{id: id}}) when is_binary(id), do: object_url(id)
  def object_url(%{pointer: id}) when is_binary(id), do: object_url(id)

  def object_url(id) when is_binary(id) do
    if Utils.is_uid?(id) do
      Utils.ap_base_url() <> "/objects/" <> id
    else
      Utils.ap_base_url() <> "/actors/" <> id
    end
  end

  def object_url(_), do: Utils.generate_object_id()

  def get_follow_activity(follow_object, followed) do
    with object_id when not is_nil(object_id) <- get_ap_id(follow_object),
         {:ok, activity} <- get_cached(ap_id: object_id) do
      {:ok, activity}
    else
      # Can't find the activity. This might be a Mastodon 2.3 "Accept"
      nil ->
        with %{} = activity <- fetch_latest_activity(follow_object["actor"], followed, "Follow") do
          {:ok, activity}
        end

      e ->
        error(e, "Could not find a matching follow")
    end
  end

  def fetch_latest_activity(actor, object, verb \\ "Follow")

  def fetch_latest_activity(%{data: %{"id" => actor}}, object, verb),
    do: fetch_latest_activity(actor, object, verb)

  def fetch_latest_activity(
        actor,
        %{
          data: %{"id" => object}
        },
        verb
      ),
      do: fetch_latest_activity(actor, object, verb)

  def fetch_latest_activity(actor, object, verb)
      when is_binary(actor) and is_binary(object) and is_binary(verb) do
    from(activity in Object)
    |> Queries.by_actor(actor)
    |> Queries.by_object(object)
    |> Queries.by_type(verb)
    |> Queries.ordered()
    |> limit(1)
    |> repo().one()
  end

  #### Like-related helpers
  @doc """
  Returns an existing like if a user already liked an object
  """
  def get_existing_like(actor, object_id) do
    query =
      from(
        object in Object,
        # this is to use the index
        where:
          fragment(
            "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
            object.data,
            object.data,
            ^object_id
          )
      )
      |> Queries.by_type("Like")
      |> Queries.by_actor(actor)
      |> debug()

    repo().one(query)
  end

  #### Announce-related helpers

  @doc """
  Retruns an existing announce activity if the notice has already been announced
  """
  def get_existing_announce(actor, %{data: %{"id" => id}}) do
    query =
      from(
        object in Object,
        # this is to use the index
        where:
          fragment(
            "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
            object.data,
            object.data,
            ^id
          )
      )
      |> Queries.by_type("Announce")
      |> Queries.by_actor(actor)

    repo().one(query)
  end

  #### Block-related helpers
  def fetch_latest_block(%{data: %{"id" => blocker_id}}, %{
        data: %{"id" => blocked_id}
      }) do
    query =
      from(
        activity in Object,
        where:
          fragment(
            "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
            activity.data,
            activity.data,
            ^blocked_id
          ),
        order_by: [fragment("? desc nulls last", activity.inserted_at)],
        limit: 1
      )
      |> Queries.by_type("Block")
      |> Queries.by_actor(blocker_id)

    repo().one(query)
  end

  def hashtags(%{"tag" => tags}) when is_list(tags) and tags != [] do
    tags
    |> Enum.filter(fn
      %{"type" => "Hashtag"} = data -> Map.has_key?(data, "name")
      plain_text when is_binary(plain_text) -> true
      _ -> false
    end)
    |> Enum.map(fn
      %{"name" => "#" <> hashtag} -> hashtag
      %{"name" => hashtag} -> hashtag
      "#" <> hashtag -> hashtag
      hashtag when is_binary(hashtag) -> hashtag
    end)
    |> Enum.uniq()
    # Note: "" elements (plain text) might occur in `data.tag` for incoming objects
    |> Enum.filter(&(&1 not in [nil, ""]))
  end

  def hashtags(%{data: data}), do: hashtags(data)
  def hashtags(_), do: []

  def replies_ids(object, limit, opts \\ []),
    do:
      object
      |> Queries.replies(opts)
      |> select([o], fragment("?->>'id'", o.data))
      |> limit(^limit)
      |> repo().all()

  def self_replies_ids(object, limit),
    do: replies_ids(object, limit, self_only: true)
end
