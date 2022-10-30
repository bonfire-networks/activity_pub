defmodule ActivityPub.Object do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  import Untangle

  alias ActivityPub.Fetcher
  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias ActivityPub.MRF
  alias Pointers.ULID
  import ActivityPub.Common
  alias ActivityPub.Utils

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @supported_activity_types ActivityPub.Config.supported_activity_types()
  @supported_actor_types ActivityPub.Config.supported_actor_types()

  schema "ap_object" do
    field(:data, :map)
    field(:local, :boolean, default: true)
    field(:public, :boolean)
    belongs_to(:pointer, Pointers.Pointer, type: ULID)

    timestamps()
  end

  def get_cached(id: id) when is_binary(id), do: do_get_cached(:id, id)
  def get_cached(ap_id: id) when is_binary(id), do: do_get_cached(:ap_id, id)
  def get_cached(pointer: id) when is_binary(id), do: do_get_cached(:pointer, id)

  def get_cached([_: %Object{} = o]), do: o

  def get_cached(id: %{id: id}) when is_binary(id), do: get_cached(id: id)
  def get_cached(pointer: %{id: id}) when is_binary(id), do: get_cached(pointer: id)
  def get_cached([{_, %{ap_id: ap_id}}]) when is_binary(ap_id), do: get_cached(ap_id: ap_id)
  def get_cached([{_, %{"id" => ap_id}}]) when is_binary(ap_id), do: get_cached(ap_id: ap_id)
  def get_cached([{_, %{data: %{"id" => ap_id}}}]) when is_binary(ap_id), do: get_cached(ap_id: ap_id)
  def get_cached(opts) do
    error(opts, "Unexpected args")
    raise "Unexpected args for get_cached"
  end

  def get_cached(opts), do: get(opts)

  defp do_get_cached(key, val), do: Utils.get_with_cache(&get/1, :ap_object_cache, key, val)

  def get_cached!(opts) do
    with {:ok, object} <- get_cached(opts) do
      object
    else e ->
      error(e)
      nil
    end
  end

  def get_uncached(opts), do: get(opts)

  defp get(id) when is_binary(id) do
    if Utils.is_ulid?(id) do
      get(pointer: id)
    else
      get(id: id)
    end
  end
  defp get(id: id) when is_binary(id) do
    case repo().get(Object, id) do
      %Object{} = object -> {:ok, object}
      _ -> {:error, :not_found}
    end
  end
  defp get(pointer: id) when is_binary(id) do
    case repo().get_by(Object, pointer_id: id) do
      %Object{} = object -> {:ok, object}
      _ -> {:error, :not_found}
    end
  end
  defp get(ap_id: ap_id) when is_binary(ap_id) do
    case repo().one(
      from(object in Object,
        # support for looking up by non-canonical URL
        where:
          fragment("(?)->>'id' = ?", object.data, ^ap_id) or
            fragment("(?)->>'url' = ?", object.data, ^ap_id)
      )
    ) do
      %Object{} = object -> {:ok, object}
      _ -> {:error, :not_found}
    end
  end
  defp get(%{data: %{"id" => ap_id}}) when is_binary(ap_id), do: get(ap_id: ap_id)
  defp get(%{"id" => ap_id}) when is_binary(ap_id), do: get(ap_id: ap_id)

  defp get(opts) do
    error(opts, "Unexpected args")
    raise "Unexpected args for Actor.get"
  end


    @doc false
  def insert(map, local?, pointer \\ nil, upsert? \\ false)
      when is_map(map) and is_boolean(local?) do
    with activity_id <- Ecto.UUID.generate(),
        map <- normalize_actors(map),
         %{} = map <- lazy_put_activity_defaults(map, pointer || activity_id),
         :ok <- Actor.check_actor_is_active(map["actor"]),
         # set some healthy boundaries
         {:ok, map} <- MRF.filter(map, local?),
         # first insert the object
         {:ok, activity, object} <-
           insert_full_object(map, local?, pointer, upsert?),
         # then insert the activity (containing only an ID as object)
         # for activities without an object
         {:ok, activity} <-
           (if is_nil(object) do
            do_insert(%{
              # activities without an object
                id: activity_id,
                data: activity,
                local: local?,
                public: Utils.public?(activity),
                pointer_id: pointer
              })
            else
              # activity containing only an ID as object
              do_insert(%{
                id: activity_id,
                data: activity,
                local: local?,
                public: Utils.public?(activity, object)
              })
            end) do
      # Splice in the child object if we have one.
      activity =
        if !is_nil(object) do
          Map.put(activity, :object, object)
        else
          activity
        end

        info(activity, "inserted activity in #{repo()}")

      {:ok, activity}
    else
      %Object{} = object ->
        warn("error while trying to insert, return the object instead")
        {:ok, object}

      error ->
        error(error, "Error while trying to save the object for federation")
    end
  end

  @doc """
  Inserts a full object if it is contained in an activity.
  """
  def insert_full_object(
        activity,
        local \\ false,
        pointer \\ nil,
        upsert? \\ false
      )

  def insert_full_object(
        %{"object" => %{"type" => type} = object_data} = activity,
        local,
        pointer,
        upsert?
      )
      when is_map(object_data) and
             type not in @supported_actor_types and
             type not in @supported_activity_types do
    # we're taking a shortcut by assuming that anything that doesn't seem like an actor or activity is an object (which is better than only supporting a specific list of object types)
    # check that it doesn't already exist
    with maybe_existing_object <- normalize(object_data, false) |> info("maybe_existing_object"),
         {:ok, data} <- prepare_data(object_data, local, pointer, activity),
         {:ok, object} <-
           maybe_upsert(upsert?, maybe_existing_object, data) do
      # return an activity that contains the ID as object rather than the actual object
      {:ok, Map.put(activity, "object", object.data["id"]), object}
    end
  end

  def insert_full_object(activity, _local, _pointer, _), do: {:ok, activity, nil}

  def do_insert(attrs) do
    attrs
    |> changeset()
    |> repo().insert()
  end

  def maybe_upsert(true, %ActivityPub.Object{} = existing_object, attrs) do
    changeset(existing_object, attrs)
    |> update_and_set_cache()
  end

  def maybe_upsert(_, %ActivityPub.Object{} = existing_object, _attrs) do
    error("Attempted to insert an object that already exists")
    debug(existing_object)
    {:ok, existing_object}
  end

  def maybe_upsert(_, _, attrs) do
    do_insert(attrs)
  end

  def set_cache(%{id: id, data: %{"id" => ap_id}} = object) do
    # TODO: store in cache only once, and only IDs for the others
    Cachex.put(:ap_object_cache, "id:#{id}", object)
    Cachex.put(:ap_object_cache, "ap_id:#{ap_id}", object)

    if object.pointer_id do
      Cachex.put(:ap_object_cache, "pointer:#{object.pointer_id}", object)
    end

    {:ok, object}
  end

  def invalidate_cache(%{id: id, data: %{"id" => ap_id}} = object) do
     Cachex.del(:ap_object_cache, "id:#{id}")
     Cachex.del(:ap_object_cache, "ap_id:#{ap_id}")
    Cachex.del(:ap_object_cache, "pointer:#{object.pointer_id}")
      :ok
  end


  def changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
  end

  def changeset(object, attrs) do
    object
    |> cast(attrs, [:id, :data, :local, :public, :pointer_id])
    |> validate_required(:data)
    |> unique_constraint(:pointer_id)
    |> unique_constraint(:ap_object__data____id_index, match: :exact)
  end

  def update_existing(object_id, attrs) do
    case get(id: object_id) do
      {:ok, object} -> do_update_existing(object, attrs)
    e ->
      error(object_id, "Could not find the object to update")
    end
  end

  def do_update_existing(%ActivityPub.Object{} = object, attrs) do
    object
    |> debug("update")
    |> change(attrs)
    |> update_and_set_cache()
  end

  def update_and_set_cache(changeset) do
    with {:ok, object} <- repo().update(changeset) do
      set_cache(object)
    else
      e -> e
    end
  rescue
    e in Ecto.ConstraintError ->
      error(e, "Could not update the AP object")
  end

  @doc false # for debugging
  def all() do
    repo().many(from(object in Object))
  end


  @doc """
  Prepares a struct to be inserted into the objects table
  """
  def prepare_data(data, local \\ false, pointer \\ nil, activity \\ nil) do
    data =
      %{}
      |> Map.put(:data, data)
      |> Map.put(:local, local)
      |> Map.put(:public, Utils.public?(data, activity))
      |> Map.put(:pointer_id, pointer)

    {:ok, data}
  end


  def lazy_put_activity_defaults(map, activity_id) do
    context = create_context(map["context"])

    map =
      map
      |> Map.put_new("id", object_url(activity_id))
      |> Map.put_new_lazy("published", &Utils.make_date/0)
      |> Map.put_new("context", context)

    if is_map(map["object"]) do
      object = map["object"]
      |> lazy_put_object_defaults(map["context"])
      |> normalize_actors()
      %{map | "object" => object}
    else
      map
    end
  end

  def lazy_put_object_defaults(map, context) do
    map
    |> Map.put_new_lazy("id", &Utils.generate_object_id/0)
    |> Map.put_new_lazy("published", &Utils.make_date/0)
    |> Utils.maybe_put("context", context)
  end

  def create_context(context) do
    context || Utils.generate_id("contexts")
  end

  def normalize(_, fetch_remote \\ true)
  def normalize({:ok, object}, _), do: object
  def normalize(%Object{} = object, _), do: object

  def normalize(%{"id" => ap_id} = object, fetch_remote)
      when is_binary(ap_id) do
    # if(length(Map.keys(object))==1) do # we only have an ID
    normalize(ap_id, fetch_remote)
    # else
    #   %{data: object}
    # end
  end

  def normalize(ap_id, false) when is_binary(ap_id),
    do: get_cached!(ap_id: ap_id)

  def normalize(ap_id, true) when is_binary(ap_id) do
    with {:ok, object} <- Fetcher.fetch_object_from_id(ap_id) do
      object
    else
      _e -> nil
    end
  end

  def normalize(_, _), do: nil

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

  def actor_from_data(%{"attributedTo" => actor} = _data), do: actor

  def actor_from_data(%{"actor" => actor} = _data), do: actor

  def actor_from_data(%{"id" => actor, "type" => type} = _data)
      when type in @supported_actor_types,
      do: actor

  def actor_from_data(%{data: data}), do: actor_from_data(data)

  def normalize_actors(params) do
    # Some implementations include actors as URIs, others inline the entire actor object, this function figures out what the URIs are based on what we have.
    params
    |> Utils.maybe_put("actor", get_ap_id(params["actor"]))
    |> Utils.maybe_put("to", get_ap_ids(params["to"]))
    |> Utils.maybe_put("bto", get_ap_ids(params["bto"]))
    |> Utils.maybe_put("cc", get_ap_ids(params["cc"]))
    |> Utils.maybe_put("bcc", get_ap_ids(params["bcc"]))
    |> Utils.maybe_put("audience", get_ap_ids(params["audience"]))
  end


  def make_tombstone(
        %Object{data: %{"id" => id, "type" => type}},
        deleted \\ DateTime.utc_now()
      ) do
    %{
      "id" => id,
      "formerType" => type,
      "deleted" => deleted,
      "type" => "Tombstone"
    }
  end

  def swap_object_with_tombstone(object) do
    tombstone = make_tombstone(object)

    object
    |> Object.changeset(%{data: tombstone})
    |> repo().update()
  end

  def delete(%Object{} = object) do
    with {:ok, _obj} <- swap_object_with_tombstone(object),
         :ok <- invalidate_cache(object) do
      {:ok, object}
    end
  end

  def get_outbox_for_actor(%{ap_id: ap_id}), do: get_outbox_for_actor(ap_id)
  def get_outbox_for_actor(ap_id) when is_binary(ap_id) do
    from(object in Object,
      where:
        fragment("(?)->>'actor' = ?", object.data, ^ap_id) and
          object.public == true,
      limit: 10
    )
    |> repo().all()
  end

  def get_outbox_for_actor(%{ap_id: ap_id}, page), do: get_outbox_for_actor(ap_id, page)
  def get_outbox_fox_actor(ap_id, page) when is_binary(ap_id)  do
    offset = (page - 1) * 10

    from(object in Object,
      where:
        fragment("(?)->>'actor' = ?", object.data, ^ap_id) and
          object.public == true,
      limit: 10,
      offset: ^offset
    )
    |> repo().all()
  end

  def get_outbox_for_instance() do
    instance = ActivityPubWeb.base_url()
    instance_filter = "#{instance}%"

    from(object in Object,
      where:
        fragment("(?)->>'actor' ilike ?", object.data, ^instance_filter) and
          object.public == true,
      limit: 10
    )
    |> repo().all()
  end

  def object_url(%{pointer_id: id}) when is_binary(id), do: object_url(id)
  def object_url(%{id: id}) when is_binary(id), do: object_url(id)
  def object_url(id) when is_binary(id), do: Utils.ap_base_url() <> "/objects/" <> id



  def fetch_latest_follow(%{data: %{"id" => follower_id}}, %{
        data: %{"id" => followed_id}
      }) do
    query =
      from(
        activity in Object,
        where:
          fragment(
            "? ->> 'type' = 'Follow'",
            activity.data
          ),
        where:
          fragment(
            "? ->> 'actor' = ?",
            activity.data,
            ^follower_id
          ),
        where:
          fragment(
            "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
            activity.data,
            activity.data,
            ^followed_id
          ),
        order_by: [fragment("? desc nulls last", activity.inserted_at)],
        limit: 1
      )

    repo().one(query)
  end

  #### Like-related helpers
  @doc """
  Returns an existing like if a user already liked an object
  """
  def get_existing_like(actor, %{data: %{"id" => id}}) do
    query =
      from(
        object in Object,
        where: fragment("(?)->>'actor' = ?", object.data, ^actor),
        # this is to use the index
        where:
          fragment(
            "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
            object.data,
            object.data,
            ^id
          ),
        where: fragment("(?)->>'type' = 'Like'", object.data)
      )

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
        where: fragment("(?)->>'actor' = ?", object.data, ^actor),
        # this is to use the index
        where:
          fragment(
            "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
            object.data,
            object.data,
            ^id
          ),
        where: fragment("(?)->>'type' = 'Announce'", object.data)
      )

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
            "? ->> 'type' = 'Block'",
            activity.data
          ),
        where:
          fragment(
            "? ->> 'actor' = ?",
            activity.data,
            ^blocker_id
          ),
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

    repo().one(query)
  end
end
