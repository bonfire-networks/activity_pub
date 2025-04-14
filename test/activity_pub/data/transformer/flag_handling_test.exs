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

  test "it accepts Flag activities for an object" do
    actor = local_actor()
    remote_actor = insert(:actor)

    activity =
      local_note_activity()
      |> debug("nooote")

    object = Object.normalize(activity)

    message =
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => remote_actor.data["id"] <> "/flag/123",
        "actor" => remote_actor.data["id"],
        "cc" => [actor.data["id"]],
        "object" => object.data["id"],
        "type" => "Flag",
        "content" => "blocked AND reported!!!"
      }
      |> debug("flaaag1")

    assert {:ok, flagged_activity} =
             Transformer.handle_incoming(message)
             |> debug("flaaag2")

    assert flagged_activity.data["object"] == [object.data["id"]]
    assert flagged_activity.data["content"] == "blocked AND reported!!!"
    assert flagged_activity.data["actor"] == remote_actor.data["id"]
    # assert flagged_activity.data["cc"] == [actor.data["id"]]
  end

  test "it accepts Flag activities for a Create activity" do
    actor = local_actor()
    remote_actor = insert(:actor)

    activity =
      local_note_activity()
      |> debug("nooote")

    object = Object.normalize(activity)

    message =
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => remote_actor.data["id"] <> "/flag/123",
        "actor" => remote_actor.data["id"],
        "cc" => [actor.data["id"]],
        "object" => activity.data["id"],
        "type" => "Flag",
        "content" => "blocked AND reported!!!"
      }
      |> debug("flaaag1")

    assert {:ok, flagged_activity} =
             Transformer.handle_incoming(message)
             |> debug("flaaag2")

    assert flagged_activity.data["object"] == [object.data["id"]] ||
             flagged_activity.data["object"] == [activity.data["id"]]

    assert flagged_activity.data["content"] == "blocked AND reported!!!"
    assert flagged_activity.data["actor"] == remote_actor.data["id"]
  end

  test "it accepts Flag activities for an object AND an actor" do
    actor = local_actor()
    remote_actor = insert(:actor)

    activity =
      local_note_activity()
      |> debug("nooote")

    object = Object.normalize(activity)

    message =
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => remote_actor.data["id"] <> "/flag/123",
        "actor" => remote_actor.data["id"],
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
    assert flagged_activity.data["actor"] == remote_actor.data["id"]
    # assert flagged_activity.data["cc"] == [actor.data["id"]]
  end

  test "accepts Flag activities for a known objects, even when an unknown one was included" do
    actor = insert(:actor)
    other_actor = insert(:actor)

    activity =
      insert(:note_activity, %{actor: actor})
      |> debug("nooote")

    object = Object.normalize(activity)

    activity2 =
      local_note_activity()
      |> debug("nooote2")

    object2 = Object.normalize(activity2)

    message =
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => other_actor.data["id"] <> "/flag/123",
        "actor" => other_actor.data["id"],
        "cc" => [actor.data["id"]],
        "object" => [object.data["id"], object2.data["id"]],
        "type" => "Flag",
        "content" => "blocked AND reported!!!"
      }
      |> debug("flaaag1")

    assert {:ok, flagged_activity} =
             Transformer.handle_incoming(message)
             |> debug("flaaag2")

    assert flagged_activity.data["object"] == [object.data["id"], object2.data["id"]]
    assert flagged_activity.data["content"] == "blocked AND reported!!!"
    assert flagged_activity.data["actor"] == other_actor.data["id"]
    # assert flagged_activity.data["cc"] == [actor.data["id"]]
  end

  test "the adapter rejects Flag activities for unknown objects" do
    actor = insert(:actor)
    other_actor = insert(:actor)

    activity =
      insert(:note_activity, %{actor: actor})
      |> debug("nooote")

    object = Object.normalize(activity)

    message =
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => other_actor.data["id"] <> "/flag/123",
        "actor" => other_actor.data["id"],
        "cc" => [actor.data["id"]],
        "object" => object.data["id"],
        "type" => "Flag",
        "content" => "blocked AND reported!!!"
      }
      |> debug("flaaag1")

    {:error, _} = Transformer.handle_incoming(message)
  end
end
