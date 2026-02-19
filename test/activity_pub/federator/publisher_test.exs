defmodule ActivityPub.Federator.APPublisherTest do
  use ActivityPub.DataCase, async: false
  alias ActivityPub.Federator.APPublisher
  import ActivityPub.Factory
  import Tesla.Mock
  alias ActivityPub.Actor
  import Tesla.Mock

  setup_all do
    mock_global(fn
      %{method: :post} ->
        %Tesla.Env{status: 200}
        #  env ->
        #   apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  test "it publishes an activity" do
    previous_queue = Oban.drain_queue(queue: :federator_outgoing)

    note_actor = local_actor()
    {:ok, note_actor} = Actor.get_cached(username: note_actor.username)
    recipient_actor = actor()

    note =
      insert(:note, %{
        actor: note_actor,
        data: %{
          "to" => [
            "https://www.w3.org/ns/activitystreams#Public"
          ],
          "cc" => [recipient_actor.ap_id, note_actor.data["followers"]]
        }
      })

    activity = insert(:note_activity, %{note: note})
    {:ok, actor} = Actor.get_cached(ap_id: activity.data["actor"])

    assert queued = APPublisher.publish(actor, activity)
    assert queued != []

    ObanHelpers.list_queue()
    |> debug("list_queue")

    queue = Oban.drain_queue(queue: :federator_outgoing)

    #  TODO: more precise
    assert queue[:success] >= (previous_queue[:success] || 0) + 1
    assert queue[:failure] == (previous_queue[:failure] || 0)
  end

  test "prepared params for a Create activity embed the full object in the JSON" do
    note_actor = local_actor()
    {:ok, note_actor} = Actor.get_cached(username: note_actor.username)
    recipient_actor = actor()

    note =
      insert(:note, %{
        actor: note_actor,
        data: %{
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [recipient_actor.ap_id, note_actor.data["followers"]]
        }
      })

    activity = insert(:note_activity, %{note: note})
    {:ok, actor} = Actor.get_cached(ap_id: activity.data["actor"])

    # Verify the stored activity input data has the object as a string URI
    assert is_binary(activity.data["object"])

    params_list = APPublisher.prepare_publish_params(actor, activity)
    assert [%{json: json, inbox: inbox} | _] = params_list
    assert is_binary(inbox)

    decoded = Jason.decode!(json)

    # The object should be embedded as a map, not just a URI
    assert is_map(decoded["object"]),
           "Expected object to be embedded as a map, got: #{inspect(decoded["object"])}"

    assert decoded["object"]["type"] == "Note"
    assert decoded["object"]["content"] == note.data["content"]
    assert decoded["object"]["id"] == note.data["id"]
    assert decoded["type"] == "Create"
  end

  # test "it adds index instance recipient if the env is set" do

  #   previous_queue = Oban.drain_queue(queue: :federator_outgoing)

  #   System.put_env(
  #     "PUSH_ALL_PUBLIC_CONTENT_TO_INSTANCE",
  #     "http://searchindex.commonspub.org/pub/shared_inbox"
  #   )

  #   note_actor = local_actor()
  #   {:ok, note_actor} = Actor.get_cached(username: note_actor.username)
  #   recipient_actor = actor()

  #   note =
  #     insert(:note, %{
  #       actor: note_actor,
  #       data: %{
  #         "to" => [
  #           recipient_actor.ap_id,
  #           "https://www.w3.org/ns/activitystreams#Public"
  #         ],
  #         "cc" => note_actor.data["followers"]
  #       }
  #     })

  #   activity = insert(:note_activity, %{note: note})
  #   {:ok, actor} = Actor.get_cached(ap_id: activity.data["actor"])

  #   assert :ok == Publisher.publish(actor, activity)

  #   assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :federator_outgoing)

  #   System.put_env("PUSH_ALL_PUBLIC_CONTENT_TO_INSTANCE", "false")
  # end
end
