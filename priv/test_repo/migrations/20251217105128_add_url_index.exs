defmodule ActivityPub.Repo.Migrations.AddURLIndex do
  @moduledoc false
  use Ecto.Migration

  def up do
    ActivityPub.Migrations.add_object_url_index()
  end

  def down do
    ActivityPub.Migrations.drop_object_url_index()
  end
end
