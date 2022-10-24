defmodule ActivityPubWeb.PublisherTest do
  alias ActivityPub.Actor
  alias ActivityPubWeb.Publisher
  import ActivityPub.Factory
  import Tesla.Mock
  use ActivityPub.DataCase

  setup do
    mock(fn
      %{method: :post} -> %Tesla.Env{status: 200}
    end)

    :ok
  end

  test "it publishes an activity" do
    previous_queue = Oban.drain_queue(queue: :federator_outgoing)

    note_actor = local_actor()
    {:ok, note_actor} = Actor.get_by_username(note_actor.username)
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
    {:ok, actor} = Actor.single_by_ap_id(activity.data["actor"])

    assert :ok == Publisher.publish(actor, activity)

    queue = Oban.drain_queue(queue: :federator_outgoing)
    assert queue[:success] == (previous_queue[:success] || 0) + 1
    assert queue[:failure] == (previous_queue[:failure] || 0)
  end

  # test "it adds index instance recipient if the env is set" do

  #   previous_queue = Oban.drain_queue(queue: :federator_outgoing)

  #   System.put_env(
  #     "PUSH_ALL_PUBLIC_CONTENT_TO_INSTANCE",
  #     "http://searchindex.commonspub.org/pub/shared_inbox"
  #   )

  #   note_actor = local_actor()
  #   {:ok, note_actor} = Actor.get_by_username(note_actor.username)
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
  #   {:ok, actor} = Actor.single_by_ap_id(activity.data["actor"])

  #   assert :ok == Publisher.publish(actor, activity)

  #   assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :federator_outgoing)

  #   System.put_env("PUSH_ALL_PUBLIC_CONTENT_TO_INSTANCE", "false")
  # end
end
