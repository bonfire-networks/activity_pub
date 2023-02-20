defmodule ActivityPub.Federator.APPublisherTest do
  use ActivityPub.DataCase, async: false
  alias ActivityPub.Federator.APPublisher
  import ActivityPub.Factory
  import Tesla.Mock
  alias ActivityPub.Actor

  setup_all do
    mock_global(fn
      %{method: :post} -> %Tesla.Env{status: 200}
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
            recipient_actor.ap_id,
            "https://www.w3.org/ns/activitystreams#Public"
          ],
          "cc" => note_actor.data["followers"]
        }
      })

    activity = insert(:note_activity, %{note: note})
    {:ok, actor} = Actor.get_cached(ap_id: activity.data["actor"])

    assert :ok == APPublisher.publish(actor, activity)

    queue = Oban.drain_queue(queue: :federator_outgoing)
    # (previous_queue[:success] || 0) + 1
    assert queue[:success] == 1
    assert queue[:failure] == (previous_queue[:failure] || 0)
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
