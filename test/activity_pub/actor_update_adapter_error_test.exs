defmodule ActivityPub.ActorUpdateAdapterErrorTest do
  @moduledoc "`update_actor` returns ok when the adapter applies a remote actor's update, and returns the adapter's error when it can't."
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import Tesla.Mock

  alias ActivityPub.Actor
  alias ActivityPub.Object

  setup do
    actor_id = "https://adapter-error-#{System.unique_integer([:positive])}.local/users/alice"
    actor(ap_id: actor_id)

    # its origin serves nothing, so the update is applied from the data given
    mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    {:ok, %Object{data: held}} = Object.get_uncached(ap_id: actor_id)

    %{actor_id: actor_id, held: held}
  end

  test "an update the adapter applies returns ok", %{actor_id: actor_id, held: held} do
    assert {:ok, _} = Actor.update_actor(actor_id, %{held | "name" => "Alice renamed"})
  end

  # TODO: an update the adapter can't apply returns the error. Needs a real way to make the adapter fail: pointing the actor at a character that doesn't exist is refused by the database.
end
