defmodule ActivityPub.Object do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  require Logger

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

  def get_by_id(id) do
    if Utils.is_ulid?(id) do
      get_by_pointer_id(id)
    else
      repo().get(Object, id)
    end
  end

  def get_by_ap_id(ap_id) do
    repo().one(
      from(object in Object,
        # support for looking up by non-canonical URL
        where:
          fragment("(?)->>'id' = ?", object.data, ^ap_id) or
            fragment("(?)->>'url' = ?", object.data, ^ap_id)
      )
    )
  end

  def get_by_pointer_id(pointer_id), do: repo().get_by(Object, pointer_id: pointer_id)

  def get_cached_by_ap_id(%{"id"=> ap_id}), do: get_cached_by_ap_id(ap_id)
  def get_cached_by_ap_id(ap_id) when is_binary(ap_id) do
    key = "ap_id:#{ap_id}"
    try do
      Cachex.fetch!(:ap_object_cache, key, fn _ ->
        object = get_by_ap_id(ap_id)

        if object do
          {:commit, object}
        else
          {:ignore, object}
        end
      end)
    catch
      _ ->
        # workaround :nodedown errors
        get_by_ap_id(ap_id)
    rescue
      _ ->
        get_by_ap_id(ap_id)
    end
  end

  def get_cached_by_pointer_id(pointer_id) do
    key = "pointer_id:#{pointer_id}"

    Cachex.fetch!(:ap_object_cache, key, fn _ ->
      object = get_by_pointer_id(pointer_id)

      if object do
        {:commit, object}
      else
        {:ignore, object}
      end
    end)
  end

  def set_cache(%Object{data: %{"id" => ap_id}} = object) do
    Cachex.put(:ap_object_cache, "ap_id:#{ap_id}", object)

    if object.pointer_id do
      Cachex.put(:ap_object_cache, "pointer_id:#{object.pointer_id}", object)
    end

    {:ok, object}
  end

  def invalidate_cache(%Object{data: %{"id" => ap_id}} = object) do
    with {:ok, true} <- Cachex.del(:ap_object_cache, "ap_id:#{ap_id}"),
         {:ok, true} <- Cachex.del(:ap_object_cache, "pointer_id:#{object.pointer_id}") do
      :ok
    end
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
  end

  def update(%ActivityPub.Object{} = object, attrs) do
    object
    |> IO.inspect(label: "update")
    |> change(attrs)
    |> update_and_set_cache()
  end

  def update(object_id, attrs) when is_binary(object_id) do
    get_by_id(object_id)
    |> __MODULE__.update(attrs)
  end

  def update(other, attrs) do
    Logger.error("no match for #{inspect other} in Activity.Object.update/2")
    {:error, :not_found}
  end

  def update_and_set_cache(changeset) do
    with {:ok, object} <- repo().update(changeset) do
      set_cache(object)
    else
      e -> e
    end
  end

  def maybe_upsert(true, %ActivityPub.Object{} = existing_object, attrs) do
    changeset(existing_object, attrs)
    |> update_and_set_cache()
  end
  def maybe_upsert(_, %ActivityPub.Object{} = existing_object, _attrs) do
    Logger.error("Attempted to insert an object that already exists")
    {:ok, existing_object}
  end
  def maybe_upsert(_, _, attrs) do
    insert(attrs)
  end

  def normalize(_, fetch_remote \\ true)
  def normalize(%Object{} = object, _), do: object
  def normalize(%{"id" => ap_id} = object, fetch_remote) when is_binary(ap_id) do
    # if(length(Map.keys(object))==1) do # we only have an ID
      normalize(ap_id, fetch_remote)
    # else
    #   %{data: object}
    # end
  end
  def normalize(ap_id, false) when is_binary(ap_id), do: get_cached_by_ap_id(ap_id)
  def normalize(ap_id, true) when is_binary(ap_id) do
    with {:ok, object} <- Fetcher.fetch_object_from_id(ap_id) do
      object
    else
      _e -> nil
    end
  end
  def normalize(_, _), do: nil

  def make_tombstone(%Object{data: %{"id" => id, "type" => type}}, deleted \\ DateTime.utc_now()) do
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

  def get_outbox_for_actor(actor) do
    from(object in Object,
      where: fragment("(?)->>'actor' = ?", object.data, ^actor.ap_id) and object.public == true,
      limit: 10
    )
    |> repo().all()
  end

  def get_outbox_fox_actor(actor, page) do
    offset = (page - 1) * 10

    from(object in Object,
      where: fragment("(?)->>'actor' = ?", object.data, ^actor.ap_id) and object.public == true,
      limit: 10,
      offset: ^offset
    )
    |> repo().all()
  end

  def get_outbox_for_instance() do
    instance = ActivityPubWeb.base_url()
    instance_filter = "#{instance}%"
    from(object in Object,
      where: fragment("(?)->>'actor' ilike ?", object.data, ^instance_filter) and object.public == true,
      limit: 10
    )
    |> repo().all()
  end
end
