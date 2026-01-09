defmodule ActivityPub.Repo.Migrations.AddURLMD5Index do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    ActivityPub.Migrations.add_object_url_index()
  end

  def down do
    ActivityPub.Migrations.drop_object_url_index()
  end
end
