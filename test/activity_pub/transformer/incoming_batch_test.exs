defmodule ActivityPub.Federator.Transformer.IncomingBatchTest do
  @moduledoc """
  A `Create`, `Like`, `Announce`, `Lock` or `Delete` whose `object` is a list (PieFed batches its announces) is handled one element at a time, each of which may fetch and store. So one delivery could make any number of fetches and rows: a batch is capped by what the instance takes of any collection (`[:instance, :federation_incoming_max_items]`), the first ones handled and the rest dropped, and a batch inside a batch only as deep as incoming threads may go (`[:instance, :federation_incoming_max_recursion]`).
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import Tesla.Mock

  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer

  setup do
    mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    n = System.unique_integer([:positive])
    liker = "https://batcher-#{n}.example/users/liker"
    actor(ap_id: liker)

    local = local_actor()
    {:ok, note_actor} = ActivityPub.Actor.get_cached(username: local.username)

    note_ids =
      for _ <- 1..3 do
        insert(:note_activity, %{actor: note_actor}).data["object"] |> Object.get_ap_id()
      end

    %{n: n, liker: liker, note_ids: note_ids}
  end

  defp put_instance_config(key, value) do
    previous = ActivityPub.Config.get([:instance, key])
    ActivityPub.Config.put([:instance, key], value)
    on_exit(fn -> ActivityPub.Config.put([:instance, key], previous) end)
  end

  defp batch(%{liker: liker, n: n}, objects) do
    %{
      "id" => "#{liker}/likes/batch-#{n}-#{System.unique_integer([:positive])}",
      "type" => "Like",
      "actor" => liker,
      "object" => objects
    }
  end

  defp delivered(doc),
    do:
      Transformer.handle_incoming(doc,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: doc["actor"]
      )

  defp liked?(%{liker: liker}, note_id),
    do: match?(%Object{}, Object.get_existing_like(liker, note_id))

  test "control: a batch within the cap is handled whole", %{note_ids: [a, b, _]} = c do
    put_instance_config(:federation_incoming_max_items, 2)

    delivered(batch(c, [a, b]))

    assert liked?(c, a)
    assert liked?(c, b)
  end

  test "a batch over the cap is handled up to it, and the rest dropped",
       %{note_ids: [a, b, d]} = c do
    put_instance_config(:federation_incoming_max_items, 2)

    delivered(batch(c, [a, b, d]))

    assert liked?(c, a)
    assert liked?(c, b)
    refute liked?(c, d), "handled past the cap"
  end

  test "a batch inside a batch goes no deeper than incoming threads may",
       %{note_ids: [a, b, d]} = c do
    put_instance_config(:federation_incoming_max_recursion, 0)

    delivered(batch(c, [a, [b, d]]))

    assert liked?(c, a), "control: the outer batch is handled"
    refute liked?(c, b), "a nested batch was handled past the recursion limit"
    refute liked?(c, d)
  end
end
