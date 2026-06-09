defmodule ActivityPub.Migrations do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

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

  @doc "Adds service_actor_uri column to ap_instance for storing discovered service/application actor URIs."
  def add_service_actor_uri do
    alter table("ap_instance") do
      add_if_not_exists(:service_actor_uri, :string)
    end
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
    drop_if_exists(index(:ap_object, ["(md5(data->>'url'))"]))
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

  @doc """
  Adds a functional index on coalesce((data)->'object'->>'id', (data)->>'object') for ap_object.
  Used by the "find Create activity wrapping a given object" lookup in Object.normalize/3.
  """
  def add_object_coalesce_index(concurrently? \\ concurrently?()) do
    create(
      index(:ap_object, ["(coalesce((data)->'object'->>'id', data->>'object'))"],
        concurrently: concurrently?
      )
    )
  end

  @doc """
  Drops the coalesce index on ap_object.
  """
  def drop_object_coalesce_index do
    drop(index(:ap_object, ["(coalesce((data)->'object'->>'id', data->>'object'))"]))
  end

  @doc """
  Membership table backing `ActivityPub.GenericCollectionStore` (the fallback store for
  collections the lib itself owns, e.g. `keyPackages`). One row per member of a collection.

  Identity (the Collection itself) lives as a normal `ap_object` row and is cached; membership
  is read fresh from this table so single-use consumption is reflected immediately.
  """
  def add_collection_member_table(concurrently? \\ concurrently?()) do
    # natural composite primary key (collection_id, object_ap_id) — no surrogate id; it also
    # enforces one membership per (collection, object)
    create_if_not_exists table("ap_collection_member", primary_key: false) do
      # the Collection ap_object this membership belongs to
      add(:collection_id, references("ap_object", type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      # the member's local ap_object (when materialised); nullable so an Add can reference a
      # remote object before it's fetched+stored
      # TODO: FEP-400e — object_id may be null for unresolved-remote members (appendable walls/forums)
      add(:object_id, references("ap_object", type: :uuid, on_delete: :delete_all))

      # the member's AP id (URI) — always set; immutable, so safe to denormalise.
      # enables URI-only rendering straight from this table (no object loads)
      add(:object_ap_id, :text, null: false, primary_key: true)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # ordered paging within a collection (FEP-1985 orderType drives ASC/DESC at query time)
    create_if_not_exists(
      index(:ap_collection_member, [:collection_id, :inserted_at, :object_ap_id],
        concurrently: concurrently?
      )
    )
  end

  @doc "Drops the `ap_collection_member` table."
  def drop_collection_member_table do
    drop_if_exists(table("ap_collection_member"))
  end
end
