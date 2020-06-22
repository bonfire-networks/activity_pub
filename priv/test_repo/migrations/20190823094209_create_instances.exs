defmodule MoodleNet.Repo.Migrations.CreateInstances do
  use Ecto.Migration

  def change do
    create_if_not_exists table("ap_instance", primary_key: false) do
      add :id, :uuid, primary_key: true
      add :host, :string
      add :unreachable_since, :naive_datetime_usec

      timestamps()
    end

    create_if_not_exists unique_index("ap_instance", [:host])
    create_if_not_exists index("ap_instance", [:unreachable_since])
  end
end
