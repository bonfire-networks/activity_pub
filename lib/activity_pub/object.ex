defmodule ActivityPub.Object do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  import Untangle

  alias ActivityPub.Fetcher
  alias ActivityPub.Object
  alias Pointers.ULID
  import ActivityPub.Common
  alias ActivityPub.Utils

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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

  @doc false # for debugging
  def all() do
    repo().many(from(object in Object))
  end

  def insert(attrs) do
    attrs
    |> changeset()
    |> repo().insert()
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
    insert(attrs)
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
end
