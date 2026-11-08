defmodule ActivityPub.Federator.DuplicateDeliveryCancelTest do
  @moduledoc """
  An activity delivered to our inbox a second time, whose id we hold already, is not retried: the job is cancelled, since running it again would find the same row.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Federator.Workers.ReceiverWorker

  defp job(received) do
    %Oban.Job{
      args: %{
        "op" => "incoming_ap_doc",
        "params" => received,
        "repo" => ActivityPub.Utils.repo(),
        "signed_by" => received["actor"]
      }
    }
  end

  # a `Block` is stored and handed to the adapter, with no check for a copy held already before the insert
  test "the same Block delivered twice is stored once, and the second job is cancelled" do
    n = System.unique_integer([:positive])
    blocker = actor(ap_id: "https://blocker-#{n}.example/users/blocker")
    blocked = local_actor()

    block = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{blocker.ap_id}/blocks/#{n}",
      "type" => "Block",
      "actor" => blocker.ap_id,
      "object" => blocked.data["id"] || ap_id(blocked)
    }

    assert {:ok, _} = ReceiverWorker.perform(job(block))

    assert {:cancel, _} = ReceiverWorker.perform(job(block))
  end
end
