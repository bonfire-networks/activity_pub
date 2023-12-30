defmodule ActivityPub.TestRepo.Migrations.CreatePointersTable  do
  @moduledoc false
  use Ecto.Migration

  def up(), do: inits(:up)
  def down(), do: inits(:down)

  defp inits(dir) do
    if Code.ensure_loaded?(Needle.Migration) do
      # init_pointers_ulid_extra(dir) # this one is optional but recommended
      # this one is not optional
      Needle.Migration.init_pointers(dir)
    end
  end
end
