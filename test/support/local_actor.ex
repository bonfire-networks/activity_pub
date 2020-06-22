defmodule ActivityPub.LocalActor do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @repo Application.get_env(:activity_pub, :repo)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "local_actor" do
    field(:data, :map)
    field(:local, :boolean)
    field(:username, :string)
    field(:keys, :string)
  end

  def get_by_id(id), do: @repo.get(__MODULE__, id)

  def get_by_ap_id(ap_id) do
    @repo.one(from(actor in __MODULE__, where: fragment("(?)->>'id' = ?", actor.data, ^ap_id)))
  end

  def get_by_username(username) do
    @repo.get_by(__MODULE__, username: username)
  end

  def insert(attrs) do
    attrs
    |> changeset()
    |> @repo.insert()
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
  end

  def changeset(object, attrs) do
    object
    |> cast(attrs, [:data, :local, :username, :keys])
    |> validate_required([:data, :username])
  end

  def update(object, attrs) do
    object
    |> change(attrs)
    |> @repo.update()
  end
end
