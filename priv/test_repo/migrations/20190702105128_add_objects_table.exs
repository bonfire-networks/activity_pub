defmodule ActivityPub.Repo.Migrations.AddObjectsTable  do
  @moduledoc false
  use Ecto.Migration

  def up do
    ActivityPub.Migrations.up()
    ActivityPub.Migrations.prepare_test()
  end

  def down do
    ActivityPub.Migrations.down()
  end
end
