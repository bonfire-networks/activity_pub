defmodule ActivityPub.Repo.Migrations.AddObjectDataReceived do
  @moduledoc false
  use Ecto.Migration

  def up do
    ActivityPub.Migrations.add_object_data_received()
  end

  def down do
    ActivityPub.Migrations.drop_object_data_received()
  end
end
