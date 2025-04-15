# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.UserDeleteHandlingTest do
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Tests.ObanHelpers

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn
      %{url: "https://mastodon.local/users/deleted"} ->
        %Tesla.Env{status: 404, body: ""}

      %{url: "https://mastodon.local/users/tombstoned"} ->
        %Tesla.Env{
          status: 200,
          body: """
          {"type": "Tombstone", "id": "https://mastodon.local/users/tombstoned"}
          """
        }

      env ->
        HttpRequestMock.request(env)
    end)

    :ok
  end

  test "delete user works for incoming user deletes where the remote actor 404s" do
    %{data: %{"id" => ap_id}} =
      insert(:actor, %{
        data: %{"id" => "https://mastodon.local/users/deleted"}
      })

    assert Object.get_cached!(ap_id: ap_id)

    data =
      file("fixtures/mastodon/mastodon-delete-user.json")
      |> Jason.decode!()

    {:ok, _} = Transformer.handle_incoming(data)
    ObanHelpers.perform_all()

    refute Object.get_cached!(ap_id: ap_id)
  end

  test "delete user works for incoming user deletes where the remote actor has a Tombstone" do
    %{data: %{"id" => ap_id}} =
      insert(:actor, %{
        data: %{"id" => "https://mastodon.local/users/tombstoned"}
      })

    assert Object.get_cached!(ap_id: ap_id)

    data =
      file("fixtures/mastodon/mastodon-delete-user.json")
      |> Jason.decode!()
      |> Map.put("object", "https://mastodon.local/users/tombstoned")

    {:ok, _} = Transformer.handle_incoming(data)
    ObanHelpers.perform_all()

    refute Object.get_cached!(ap_id: ap_id)
  end

  test "delete user fails when actor still exists on origin instance" do
    %{data: %{"id" => ap_id}} =
      insert(:actor, %{
        data: %{"id" => "https://mastodon.local/users/admin"}
      })

    assert Object.get_cached!(ap_id: ap_id)

    data =
      file("fixtures/mastodon/mastodon-delete-user.json")
      |> Jason.decode!()
      |> Map.put("object", "https://mastodon.local/users/admin")

    assert {:error, _} = Transformer.handle_incoming(data)
    ObanHelpers.perform_all()

    assert Object.get_cached!(ap_id: ap_id)
  end

  test "delete user skips incoming user deletes that are unknown to our instance" do
    data =
      file("fixtures/mastodon/mastodon-delete-user.json")
      |> Jason.decode!()

    refute match?({:ok, %{}}, Transformer.handle_incoming(data))
  end

  test "delete user fails for incoming user deletes with spoofed origin" do
    ap_id = ap_id(actor(local: false))

    data =
      file("fixtures/mastodon/mastodon-delete-user.json")
      |> Jason.decode!()
      |> Map.put("object", ap_id)

    assert match?({:error, _}, Transformer.handle_incoming(data))
  end
end
