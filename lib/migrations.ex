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

  def concurrently?, do: System.get_env("DB_MIGRATE_INDEXES_CONCURRENTLY") != "false"

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

    concurrently? = concurrently?()

    create(unique_index(:ap_object, ["(data->>'id')"], concurrently: concurrently?))
    create(unique_index(:ap_object, [:pointer_id], concurrently: concurrently?))
    add_object_url_index(concurrently?)

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
      add_if_not_exists(:is_object, :boolean, default: false, null: false)
    end
  end

  def drop_object_boolean do
    alter(table("ap_object")) do
      remove(:is_object)
    end
  end

  @doc """
  Adds a non-unique index on md5(data->>'url') for ap_object.
  Uses MD5 hash to handle URLs longer than the btree index limit of 2704 bytes.
  Automatically migrates from old full-URL index if it exists.
  """
  def add_object_url_index(concurrently? \\ concurrently?()) do
    # Drop old full-URL index if it exists (may fail silently, that's ok)
    drop_if_exists(index(:ap_object, ["(data->>'url')"]))
    # Create new MD5 hash-based index
    create(index(:ap_object, ["(md5(data->>'url'))"], concurrently: concurrently?))
  end

  @doc """
  Drops the MD5 hash index on (data->>'url') for ap_object.
  """
  def drop_object_url_index do
    drop(index(:ap_object, ["(md5(data->>'url')))"]))
  end

  @doc """
  Adds a non-unique index on (data->>'inReplyTo') for ap_object
  """
  def add_object_in_reply_to_index(concurrently? \\ concurrently?()) do
    create(index(:ap_object, ["(data->>'inReplyTo')"], concurrently: concurrently?))
  end

  @doc """
  Drops the index on (data->>'inReplyTo') for ap_object.
  """
  def drop_object_in_reply_to_index do
    drop(index(:ap_object, ["(data->>'inReplyTo')"]))
  end
end
