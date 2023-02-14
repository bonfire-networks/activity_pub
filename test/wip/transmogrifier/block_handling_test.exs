# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Transmogrifier.BlockHandlingTest do
  use ActivityPub.DataCase, async: true

  alias ActivityPub.Object, as: Activity
  
  alias ActivityPubWeb.Transmogrifier

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  @tag :todo
  test "it works for incoming blocks" do
    user = local_actor()

    data =
      file("fixtures/mastodon/mastodon-block-activity.json")
      |> Jason.decode!()
      |> Map.put("object", ap_id(user))

    blocker = local_actor(ap_id: data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["type"] == "Block"
    assert Object.get_ap_id(data["object"]) =~ (ap_id(user))
    assert data["actor"] == "https://mastodon.local/users/admin"

    assert is_blocked?(blocker, user)
  end

  test "incoming blocks successfully tear down any follow relationship" do
    blocker = local_actor()
    blocked = local_actor()

    data =
      file("fixtures/mastodon/mastodon-block-activity.json")
      |> Jason.decode!()
      |> Map.put("object", blocked.data["id"] || ap_id(blocked))
      |> Map.put("actor", blocker.data["id"] || ap_id(blocker))

    {:ok, _} = follow(blocker, blocked)
    {:ok, _} = follow(blocked, blocker)

    assert following?(blocker, blocked)
    assert following?(blocked, blocker)

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["type"] == "Block"
    assert Object.get_ap_id(data["object"]) =~ (blocked.data["id"] || ap_id(blocked))
    assert data["actor"] == (blocker.data["id"] || ap_id(blocker))

    blocker = user_by_ap_id(data["actor"])
    blocked = user_by_ap_id(data["object"])

    assert is_blocked?(blocker, blocked)

    refute following?(blocker, blocked)
    refute following?(blocked, blocker)
  end
end
