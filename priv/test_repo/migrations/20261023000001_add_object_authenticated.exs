defmodule ActivityPub.Repo.Migrations.AddObjectAuthenticated do
  @moduledoc false
  use Ecto.Migration

  def up do
    ActivityPub.Migrations.add_object_authenticated()
  end

  def down do
    ActivityPub.Migrations.drop_object_authenticated()
  end
end
