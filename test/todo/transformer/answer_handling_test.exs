# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.AnswerHandlingTest do
  use ActivityPub.DataCase, async: true

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "incoming, rewrites Note to Answer and increments vote counters" do
    user = local_actor()

    activity =
      insert(:note_activity, %{
        actor: user,
        status: "suya...",
        poll: %{options: ["suya", "suya.", "suya.."], expires_in: 10}
      })

    object = Object.normalize(activity, fetch: false)
    assert object.data["repliesCount"] == nil

    data =
      file("fixtures/mastodon/mastodon-vote.json")
      |> Jason.decode!()
      |> Kernel.put_in(["to"], ap_id(user))
      |> Kernel.put_in(["object", "inReplyTo"], object.data["id"])
      |> Kernel.put_in(["object", "to"], ap_id(user))

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)
    answer_object = Object.normalize(activity, fetch: false)
    assert answer_object.data["type"] == "Answer"
    assert answer_object.data["inReplyTo"] == object.data["id"]

    new_object = Object.get_cached!(ap_id: object.data["id"])
    assert new_object.data["repliesCount"] == nil

    assert Enum.any?(
             new_object.data["oneOf"],
             fn
               %{"name" => "suya..", "replies" => %{"totalItems" => 1}} -> true
               _ -> false
             end
           )
  end

  test "outgoing, rewrites Answer to Note" do
    user = local_actor()

    poll_activity =
      insert(:note_activity, %{
        actor: user,
        status: "suya...",
        poll: %{options: ["suya", "suya.", "suya.."], expires_in: 10}
      })

    poll_object = Object.normalize(poll_activity, fetch: false)
    # TODO: Replace with CommonAPI vote creation when implemented
    data =
      file("fixtures/mastodon/mastodon-vote.json")
      |> Jason.decode!()
      |> Kernel.put_in(["to"], ap_id(user))
      |> Kernel.put_in(["object", "inReplyTo"], poll_object.data["id"])
      |> Kernel.put_in(["object", "to"], ap_id(user))

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)
    {:ok, data} = Transformer.prepare_outgoing(activity.data)

    assert data["object"]["type"] == "Note"
  end
end
