defmodule ActivityPub.Federator.RelayedStoredActivityTest do
  @moduledoc """
  An `Announce` of an activity we already hold sends the stored copy to the adapter, with who relayed it: the group accepted what our moderator did, or a remote activity we refused before learning its sender moderates the group can now apply.

  Only the group the stored activity names (its `audience`, and a ban's `target`) can say that. The ids of such activities are public (a ban goes to Public and the group relays it), so anyone could otherwise relay one and have the adapter act on it again.
  """
  use ActivityPub.DataCase, async: false
  use Repatch.ExUnit

  import ActivityPub.Factory

  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Object

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    test_pid = self()
    Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    Repatch.patch(Adapter.adapter(), :handle_activity, [mode: :shared], fn activity ->
      send(test_pid, {:handed_over, activity.data["id"], activity.relayed_by})
      {:ok, :handled}
    end)

    n = System.unique_integer([:positive])
    group = "https://groups-#{n}.example/c/g"
    stranger = "https://stranger-#{n}.example/u/s"
    moderator = "https://mod-#{n}.example/u/mod"
    for id <- [group, stranger, moderator], do: actor(ap_id: id)

    %{n: n, group: group, stranger: stranger, moderator: moderator}
  end

  # the relay, as it reaches us: an Announce by `by`, which came in with a verified HTTP signature
  defp relay(by, activity) do
    Transformer.handle_incoming(
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Announce",
        "id" => "#{by}/activities/announce/#{System.unique_integer([:positive])}",
        "actor" => by,
        "to" => [@public],
        "object" => activity
      },
      from_inbox: true,
      authenticated: :http_signature,
      signed_by: by
    )
  end

  for local? <- [false, true], {type, named} <- [{"Lock", "audience"}, {"Block", "target"}] do
    test "a #{type} we hold (local: #{local?}) relayed by a stranger is not handed to the adapter; by the group it names, it is",
         %{n: n, group: group, stranger: stranger, moderator: moderator} do
      {:ok, %{data: data}} =
        Object.insert(
          %{
            "id" => "https://mod-#{n}.example/activities/#{unquote(type)}-#{n}",
            "type" => unquote(type),
            "actor" => moderator,
            unquote(named) => group,
            "object" => "https://mod-#{n}.example/post/1",
            "to" => [@public]
          },
          unquote(local?)
        )

      id = data["id"]

      relay(stranger, data)
      refute_received {:handed_over, ^id, _}

      relay(group, data)

      assert_received {:handed_over, ^id, ^group},
                      "control: the group's relay of it still reaches the adapter"
    end
  end
end
