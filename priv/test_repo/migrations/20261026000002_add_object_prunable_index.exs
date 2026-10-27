defmodule ActivityPub.Repo.Migrations.AddObjectPrunableIndex do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    ActivityPub.Migrations.add_object_prunable_index()
  end

  def down do
    ActivityPub.Migrations.drop_object_prunable_index()
  end
end
