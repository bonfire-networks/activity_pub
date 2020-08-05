defmodule ActivityPub.Migrations do
  use Ecto.Migration
  import Pointers.Migration

  def up do
    create table("ap_object", primary_key: false) do
      add :id, :uuid, primary_key: true
      add :data, :map
      add :local, :boolean
      add :public, :boolean
      add :pointer_id, weak_pointer()

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ap_object, ["(data->>'id')"])
    create unique_index(:ap_object, [:pointer_id])
  end

  def down do
    drop table("ap_object")
    drop index(:ap_object, ["(data->>'id')"])
    drop index(:ap_object, [:pointer_id])
  end
end
