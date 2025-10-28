defmodule ActivityPub.Migrations do
  @moduledoc false
  use Ecto.Migration
  @disable_ddl_transaction true

  defp ap_add_pointer_id() do
    if Code.ensure_loaded?(Needle.Migration) do
      Needle.Migration.add_pointer(:pointer_id, :weak, Needle.Pointer)
    else
      add(:pointer_id, :uuid)
    end
  end

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS citext")

    create table("ap_object", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:data, :map)
      add(:local, :boolean, default: false, null: false)
      add(:public, :boolean, default: false, null: false)
      ap_add_pointer_id()

      timestamps(type: :utc_datetime_usec)
    end

    concurrently? = System.get_env("DB_MIGRATE_INDEXES_CONCURRENTLY") != "false"

    create(unique_index(:ap_object, ["(data->>'id')"], concurrently: concurrently?))
    create(unique_index(:ap_object, [:pointer_id], concurrently: concurrently?))

    create table("ap_instance", primary_key: false) do
      add(:id, :uuid, primary_key: concurrently?)
      add(:host, :string)
      add(:unreachable_since, :naive_datetime_usec)

      timestamps()
    end

    create(unique_index("ap_instance", [:host], concurrently: concurrently?))
    create(index("ap_instance", [:unreachable_since], concurrently: concurrently?))
  end

  def prepare_test do
    # This local_actor table only exists for test purposes
    create_if_not_exists table("local_actor", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:username, :citext)
      add(:data, :map)
      add(:local, :boolean, default: false, null: false)
      add(:keys, :text)
      add(:followers, {:array, :string})
    end
  end

  def down do
    drop(table("ap_object"))
    # drop index(:ap_object, ["(data->>'id')"])
    # drop index(:ap_object, [:pointer_id])
    drop(table("ap_instance"))
    # drop index("ap_instance", [:host])
    # drop index("ap_instance", [:unreachable_since])
  end

  def add_object_boolean do
    alter(table("ap_object")) do
      add(:is_object, :boolean, default: false, null: false)
    end
  end

  def drop_object_boolean do
    alter(table("ap_object")) do
      remove(:is_object)
    end
  end
end
