defmodule ActivityPub.Migrations do
  use Ecto.Migration
  import Pointers.Migration

  def change do
    create table("ap_object", primary_key: false) do
      add :id, :uuid, primary_key: true
      add :data, :map
      add :local, :boolean
      add :public, :boolean
      add :pointer, weak_pointer()

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ap_object, ["(data->>'id')"])
  end
end
