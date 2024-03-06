defmodule ActivityPub.Federator.TransformerFlagTest do
  use ActivityPub.DataCase, async: false
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Actor
  alias ActivityPub.Object

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    mock_global(fn
      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  test "it accepts Flag activities" do
    actor = insert(:actor)
    other_actor = insert(:actor)

    activity = insert(:note_activity, %{actor: actor})
    object = Object.normalize(activity)

    message =
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => other_actor.data["id"] <> "/flag/123",
        "actor" => other_actor.data["id"],
        "cc" => [actor.data["id"]],
        "object" => [actor.data["id"], object.data["id"]],
        "type" => "Flag",
        "content" => "blocked AND reported!!!"
      }
      |> debug("flaaag1")

    assert {:ok, flagged_activity} =
             Transformer.handle_incoming(message)
             |> debug("flaaag2")

    assert flagged_activity.data["object"] == [actor.data["id"], object.data["id"]]
    assert flagged_activity.data["content"] == "blocked AND reported!!!"
    assert flagged_activity.data["actor"] == other_actor.data["id"]
    # assert flagged_activity.data["cc"] == [actor.data["id"]]
  end
end
