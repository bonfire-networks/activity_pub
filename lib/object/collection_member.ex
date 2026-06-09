defmodule ActivityPub.Object.CollectionMember do
  @moduledoc """
  Membership row backing `ActivityPub.GenericCollectionStore`: one per member of a
  lib-owned collection (e.g. an actor's `keyPackages`).

  Each row carries both `object_id` (FK to the local `ap_object`, for joins/cascade/embedded
  rendering) and `object_ap_id` (the immutable URI, for cheap URI-only rendering and to hold a
  member referenced before it's resolved to a local row).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ActivityPub.Object

  @type t :: %__MODULE__{}

  # natural composite primary key: (collection_id, object_ap_id) — no surrogate id
  @primary_key false
  @foreign_key_type :binary_id

  schema "ap_collection_member" do
    belongs_to(:collection, Object, primary_key: true)
    belongs_to(:object, Object)
    field(:object_ap_id, :string, primary_key: true)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:collection_id, :object_id, :object_ap_id])
    |> validate_required([:collection_id, :object_ap_id])
    |> unique_constraint([:collection_id, :object_ap_id], name: :ap_collection_member_pkey)
  end
end
