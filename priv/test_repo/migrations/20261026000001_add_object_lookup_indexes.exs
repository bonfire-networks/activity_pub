defmodule ActivityPub.Repo.Migrations.AddObjectLookupIndexes do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    ActivityPub.Migrations.add_object_actor_index()
    ActivityPub.Migrations.add_object_username_index()
    ActivityPub.Migrations.add_object_recipients_index()
  end

  def down do
    ActivityPub.Migrations.drop_object_recipients_index()
    ActivityPub.Migrations.drop_object_username_index()
    ActivityPub.Migrations.drop_object_actor_index()
  end
end
