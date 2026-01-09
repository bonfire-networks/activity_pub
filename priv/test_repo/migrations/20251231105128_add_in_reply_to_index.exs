defmodule ActivityPub.Repo.Migrations.AddInReplyToIndex do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    ActivityPub.Migrations.add_object_in_reply_to_index()
  end

  def down do
    ActivityPub.Migrations.drop_object_in_reply_to_index()
  end
end
