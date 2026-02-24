defmodule ActivityPub.Repo.Migrations.AddServiceActorUri do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    ActivityPub.Migrations.add_service_actor_uri()
  end

  def down do
    alter table("ap_instance") do
      remove(:service_actor_uri)
    end
  end
end
