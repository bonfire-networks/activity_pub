defmodule ActivityPub.TestAdapter do
  @behaviour ActivityPub.Federator.Adapter

  defp format_actor({:ok, actor}), do: actor

  defp format_actor(actor) do
    %ActivityPub.Actor{
      id: actor.id,
      data: actor.data,
      local: true,
      keys: actor.keys,
      ap_id: actor.data["id"],
      username: actor.data["preferredUsername"],
      deactivated: false,
      pointer_id: actor.id
    }
  end

  def get_actor_by_username(username) do
    case ActivityPub.LocalActor.get_cached(username: username) do
      nil -> {:error, :not_found}
      actor -> {:ok, format_actor(actor)}
    end
  end

  def get_actor_by_id(id) do
    case ActivityPub.LocalActor.get(id: id) do
      nil -> {:error, :not_found}
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
    actor = ActivityPub.LocalActor.get_cached(username: actor.username)
    {:ok, updated_actor} = ActivityPub.LocalActor.update(actor, params)
    {:ok, format_actor(updated_actor)}
  end

  def update_remote_actor(_term) do
    :ok
  end

  def handle_activity(_term) do
    :ok
  end

  def get_follower_local_ids(actor, _purpose_or_current_actor \\ nil) do
    actor = ActivityPub.LocalActor.get(pointer: actor.pointer_id)
    actor.followers
  end

  def base_url(), do: ActivityPub.Web.Endpoint.url()
end
