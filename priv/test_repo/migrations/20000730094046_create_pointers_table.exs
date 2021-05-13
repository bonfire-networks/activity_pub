defmodule ActivityPub.TestRepo.Migrations.CreatePointersTable do
  use Ecto.Migration
  import Pointers.Migration

  def up(), do: inits(:up)
  def down(), do: inits(:down)

  defp inits(dir) do
    # init_pointers_ulid_extra(dir) # this one is optional but recommended
    # this one is not optional
    init_pointers(dir)
  end
end
