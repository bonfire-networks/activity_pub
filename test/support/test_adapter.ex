defmodule ActivityPub.TestAdapter do
  @behaviour ActivityPub.Adapter

  defp format_actor(actor) do
    %ActivityPub.Actor{
      id: actor.id,
      data: actor.data,
      local: true,
      keys: actor.keys,
      ap_id: actor.data["preferredUsername"],
      username: actor.data["preferredUsername"]
    }
  end

  def get_actor_by_username(username) do
    case ActivityPub.LocalActor.get_by_username(username) do
      nil -> {:error, "not found"}
      actor -> {:ok, format_actor(actor)}
    end
  end

  def get_actor_by_id(id) do
    case ActivityPub.LocalActor.get_by_id(id) do
      nil -> {:error, "not found"}
      actor -> {:ok, format_actor(actor)}
    end
  end

  def maybe_create_remote_actor(object) do
    host = URI.parse(object.data["id"]).host
    username = object.data["preferredUsername"] <> host

    ActivityPub.LocalActor.insert(%{
      local: false,
      data: object.data,
      username: username
    })
  end

  def update_local_actor(actor, params) do
    actor = ActivityPub.LocalActor.get_by_username(actor.username)
    ActivityPub.LocalActor.update(actor, params)
  end

  def update_remote_actor(_term) do
    :ok
  end

  def handle_activity(_term) do
    :ok
  end
end
