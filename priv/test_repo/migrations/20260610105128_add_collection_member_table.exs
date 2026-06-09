defmodule ActivityPub.TestRepo.Migrations.AddCollectionMemberTable do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    ActivityPub.Migrations.add_collection_member_table()
  end

  def down do
    ActivityPub.Migrations.drop_collection_member_table()
  end
end
