defmodule ActivityPub.Federator.Transformer.IncomingVerbsHazardsTest do
  @moduledoc """
  What has to keep working while received activities move from being rebuilt to being stored as their author sent them, and what was found broken on the way.

  - An `Undo` finds the activity it takes back whatever shape that was stored in: a `Like` or an `Announce` stored as received has no `"context"` key unless its author sent one, where a rebuilt one always had it.
  - A `Like` is one per actor and object, whatever its id.
  - A received `Undo` is stored as its author sent it, not with our stored copy of what it takes back in its place.
  - An `Undo` of a `Block` we never stored is refused, not a crash.
  - An activity whose nested objects are stored on their own (and so no longer what its signature covered) does not keep that signature.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import Tesla.Mock

  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    # nothing is served: whatever is needed is stored first
    mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    n = System.unique_integer([:positive])
    host = "https://hazards-#{n}.example"
    author_id = "#{host}/users/author"
    other_id = "#{host}/users/other"
    actor(ap_id: author_id)
    actor(ap_id: other_id)

    # a post the adapter holds, so liking it reaches the adapter as it would for real
    local = local_actor()
    {:ok, note_actor} = ActivityPub.Actor.get_cached(username: local.username)
    note_activity = insert(:note_activity, %{actor: note_actor})

    %{
      n: n,
      host: host,
      author_id: author_id,
      other_id: other_id,
      note_id: Object.get_ap_id(note_activity.data["object"])
    }
  end

  defp delivered(document),
    do:
      Transformer.handle_incoming(document,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: document["actor"]
      )

  # a row as an activity stored as received is: only the fields its author sent
  defp stored_as_received(activity) do
    assert {:ok, %Object{data: data}} = Object.insert(activity, false)
    refute Map.has_key?(data, "context"), "control: the stored activity has no context key"
    data
  end

  defp undo_of(%{other_id: other_id, n: n}, activity) do
    %{
      "id" => "#{other_id}/undos/#{n}",
      "type" => "Undo",
      "actor" => other_id,
      "to" => [@public],
      "object" => Map.take(activity, ["id", "type", "actor", "object"])
    }
  end

  describe "an Undo of an activity stored without a context" do
    test "takes back a Like", context do
      like =
        stored_as_received(%{
          "id" => "#{context.other_id}/likes/#{context.n}",
          "type" => "Like",
          "actor" => context.other_id,
          "object" => context.note_id
        })

      assert {:ok, _} = delivered(undo_of(context, like))

      assert {:error, :not_found} = Object.get_uncached(ap_id: like["id"]),
             "the Like was not taken back"
    end

    test "takes back an Announce", context do
      announce =
        stored_as_received(%{
          "id" => "#{context.other_id}/announces/#{context.n}",
          "type" => "Announce",
          "actor" => context.other_id,
          "to" => [@public],
          "object" => context.note_id
        })

      assert {:ok, _} = delivered(undo_of(context, announce))

      assert {:error, :not_found} = Object.get_uncached(ap_id: announce["id"]),
             "the Announce was not taken back"
    end
  end

  test "a second Like of the same object by the same actor, with another id, is not a second like",
       context do
    like = fn id ->
      %{
        "id" => "#{context.other_id}/likes/#{id}",
        "type" => "Like",
        "actor" => context.other_id,
        "object" => context.note_id
      }
    end

    assert {:ok, _} = delivered(like.("first"))
    delivered(like.("second"))

    assert %Object{data: %{"id" => id}} =
             Object.get_existing_like(context.other_id, context.note_id)

    assert id == like.("first")["id"]

    assert {:error, :not_found} = Object.get_uncached(ap_id: like.("second")["id"]),
           "the second Like was stored as well"
  end

  # a reboost leaves two by one actor of one object: the existing one is the latest, rather than a query that expects one raising
  test "with two Announces of an object by one actor, the existing one is the latest", context do
    announce = fn id, published ->
      assert {:ok, _} =
               Object.insert(
                 %{
                   "id" => "#{context.other_id}/announces/#{id}",
                   "type" => "Announce",
                   "actor" => context.other_id,
                   "to" => [@public],
                   "object" => context.note_id,
                   "published" => published
                 },
                 false
               )
    end

    announce.("first", "2026-10-20T09:00:00Z")
    announce.("second", "2026-10-21T09:00:00Z")

    assert %Object{data: %{"id" => id}} =
             Object.get_existing_announce(context.other_id, %{data: %{"id" => context.note_id}})

    assert id == "#{context.other_id}/announces/second"
  end

  test "a received Undo is stored as its author sent it", context do
    like = %{
      "id" => "#{context.other_id}/likes/#{context.n}",
      "type" => "Like",
      "actor" => context.other_id,
      "object" => context.note_id
    }

    assert {:ok, _} = delivered(like)

    undo = context |> undo_of(like) |> Map.put("extension", "an extension field")
    assert {:ok, _} = delivered(undo)

    assert {:ok, %Object{data: stored}} = Object.get_uncached(ap_id: undo["id"])

    assert stored["extension"] == "an extension field",
           "the Undo was rebuilt, losing what its author wrote"

    # normalised, not rebuilt: `Object.insert` gives an embedded object a `published` when it has none, while our copy of the Like would carry the `to`, `cc` and `context` its builder made
    assert Map.delete(stored["object"], "published") == undo["object"],
           "the Undo was stored with our copy of the Like as its object, not the one its author sent"
  end

  test "an Undo of a Block we never stored is refused, not a crash", context do
    undo =
      undo_of(context, %{
        "id" => "#{context.other_id}/blocks/#{context.n}",
        "type" => "Block",
        "actor" => context.other_id,
        "object" => context.author_id
      })

    result =
      try do
        delivered(undo)
      rescue
        e -> flunk("an Undo of an unknown Block raised: #{Exception.message(e)}")
      end

    refute match?({:ok, %Object{}}, result), "an Undo of nothing was stored"
  end

  test "an activity whose nested objects are stored on their own does not keep its stale signature",
       context do
    arrive = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{context.author_id}/arrivals/#{context.n}",
      "type" => "Arrive",
      "actor" => context.author_id,
      "to" => [@public],
      "location" => %{
        "id" => "#{context.host}/places/#{context.n}",
        "type" => "Place",
        "name" => "Somewhere"
      },
      "signature" => %{
        "type" => "RsaSignature2017",
        "creator" => "#{context.author_id}#main-key",
        "signatureValue" => "covers the document with its Place embedded"
      }
    }

    assert {:ok, _} = delivered(arrive)

    assert {:ok, %Object{data: stored}} = Object.get_uncached(ap_id: arrive["id"])

    assert stored["location"] == arrive["location"]["id"],
           "control: the Place was stored on its own, leaving its id"

    refute Map.has_key?(stored, "signature"),
           "the signature no longer covers what is stored, but was kept with it"
  end
end
