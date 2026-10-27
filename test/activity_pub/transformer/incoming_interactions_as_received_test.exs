defmodule ActivityPub.Federator.Transformer.IncomingInteractionsAsReceivedTest do
  @moduledoc """
  A `Like` or a boost (`Announce`) from another instance is stored as its author sent it, normalised but not rebuilt, as a `Create` is: whatever the author wrote is kept (their addressing, `published`, extension fields), and the builder only fills what they left out.

  Its `object` is kept as the id of what it is about, as the builder makes it: an object embedded in a like or a boost is not stored as one of its own on the liker's word.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import Tesla.Mock

  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    n = System.unique_integer([:positive])
    other_id = "https://interactions-#{n}.example/users/other"
    actor(ap_id: other_id)

    # a public post the adapter holds, as a liked or boosted one is
    local = local_actor()
    {:ok, note_actor} = ActivityPub.Actor.get_cached(username: local.username)
    note_activity = insert(:note_activity, %{actor: note_actor})

    %{n: n, other_id: other_id, note_id: Object.get_ap_id(note_activity.data["object"])}
  end

  defp delivered(document),
    do:
      Transformer.handle_incoming(document,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: document["actor"]
      )

  defp stored(ap_id) do
    assert {:ok, %Object{data: data}} = Object.get_uncached(ap_id: ap_id)
    data
  end

  defp interaction(type, context, extra) do
    Map.merge(
      %{
        "id" => "#{context.other_id}/#{type}/#{context.n}",
        "type" => type,
        "actor" => context.other_id,
        "object" => context.note_id
      },
      extra
    )
  end

  describe "a received Follow" do
    setup do
      followed = local_actor()
      {:ok, followed} = ActivityPub.Actor.get_cached(username: followed.username)
      %{followed_id: followed.ap_id}
    end

    test "keeps what its author wrote, with the state we track", context do
      followers = "#{context.other_id}/followers"

      received =
        interaction("Follow", context, %{
          "object" => context.followed_id,
          "to" => [context.followed_id],
          "cc" => [followers],
          "published" => "2026-10-24T09:00:00Z",
          "extension" => "an extension field"
        })

      assert {:ok, _} = delivered(received)

      assert %{
               "id" => id,
               "cc" => [^followers],
               "published" => "2026-10-24T09:00:00Z",
               "extension" => "an extension field",
               "state" => state
             } = stored(received["id"])

      assert id == received["id"]
      assert state in ["pending", "accept"], "the state we track was not set"
    end

    test "keeps the id of who it follows as its object, not an actor embedded in it", context do
      received =
        interaction("Follow", context, %{
          "object" => %{"id" => context.followed_id, "type" => "Person", "name" => "claimed"}
        })

      assert {:ok, _} = delivered(received)

      assert stored(received["id"])["object"] == context.followed_id
    end

    test "is taken back by an Undo stored as its author sent it", context do
      follow = interaction("Follow", context, %{"object" => context.followed_id})
      assert {:ok, _} = delivered(follow)

      undo = %{
        "id" => "#{context.other_id}/undos/#{context.n}",
        "type" => "Undo",
        "actor" => context.other_id,
        "object" => Map.take(follow, ["id", "type", "actor", "object"]),
        "extension" => "an extension field"
      }

      assert {:ok, _} = delivered(undo)

      assert %{"extension" => "an extension field", "object" => object} = stored(undo["id"]),
             "the Undo was rebuilt, losing what its author wrote"

      # normalised, not rebuilt: `Object.insert` gives an embedded object a `published` when it has none, while our copy of the Follow would carry the `state` and `to` we gave it
      assert Map.delete(object, "published") == undo["object"]
    end
  end

  # what we own in a report: its `state`, its reason gathered from `summary` and `content`, the list of what it reports, and an empty `to`, which keeps it private
  test "a received Flag keeps what its author wrote, with the report fields we own", context do
    reported = local_actor()
    {:ok, reported} = ActivityPub.Actor.get_cached(username: reported.username)

    received =
      interaction("Flag", context, %{
        "object" => reported.ap_id,
        "to" => [reported.ap_id],
        "summary" => "the reason",
        "content" => "more about it",
        "published" => "2026-10-24T09:00:00Z",
        "extension" => "an extension field"
      })

    assert {:ok, _} = delivered(received)

    assert %{
             "published" => "2026-10-24T09:00:00Z",
             "extension" => "an extension field",
             "summary" => "the reason",
             "state" => "open",
             "content" => "the reason\n\nmore about it",
             "object" => [reported_id],
             "to" => []
           } = stored(received["id"])

    assert reported_id == reported.ap_id
  end

  describe "a received Block" do
    setup do
      blocked = local_actor()
      {:ok, blocked} = ActivityPub.Actor.get_cached(username: blocked.username)
      %{blocked_id: blocked.ap_id}
    end

    test "keeps what its author wrote, with the id of who it blocks as its object", context do
      received =
        interaction("Block", context, %{
          "object" => context.blocked_id,
          "cc" => ["#{context.other_id}/followers"],
          "published" => "2026-10-24T09:00:00Z",
          "extension" => "an extension field"
        })

      assert {:ok, _} = delivered(received)

      assert %{
               "cc" => [_],
               "published" => "2026-10-24T09:00:00Z",
               "extension" => "an extension field",
               "object" => blocked_id
             } = stored(received["id"])

      assert blocked_id == context.blocked_id
    end

    test "is taken back by an Undo stored as its author sent it", context do
      block = interaction("Block", context, %{"object" => context.blocked_id})
      assert {:ok, _} = delivered(block)

      undo = %{
        "id" => "#{context.other_id}/undos/#{context.n}",
        "type" => "Undo",
        "actor" => context.other_id,
        "object" => Map.take(block, ["id", "type", "actor", "object"]),
        "extension" => "an extension field"
      }

      assert {:ok, _} = delivered(undo)

      assert %{"extension" => "an extension field", "object" => object} = stored(undo["id"]),
             "the Undo was rebuilt, losing what its author wrote"

      # normalised, not rebuilt (see the `Undo` of a `Follow`)
      assert Map.delete(object, "published") == undo["object"]
    end
  end

  describe "a received answer to our Follow" do
    # a follow request the adapter holds, waiting for the followed one's answer, as `accept_handling_test.exs` makes it
    setup do
      follower = local_actor()
      followed = local_actor(request_before_follow: true)
      {:ok, follow} = follow(follower, followed)

      %{
        follow_id: ap_object_from_outgoing(follow).data["id"],
        followed_id: followed.data["id"] || ap_id(followed)
      }
    end

    defp answer(type, context) do
      %{
        "id" => "#{context.followed_id}/#{type}/#{context.n}",
        "type" => type,
        "actor" => context.followed_id,
        "object" => context.follow_id,
        "cc" => ["#{context.followed_id}/followers"],
        "published" => "2026-10-24T09:00:00Z",
        "extension" => "an extension field"
      }
    end

    # its `object` stays our stored Follow, now accepted: Bonfire reads its `actor` to know whose blocks and allowlists apply (`object_implied_actor_ids/1`)
    test "an Accept keeps what its author wrote, with our accepted Follow as its object",
         context do
      received = answer("Accept", context)
      assert {:ok, _} = delivered(received)

      assert %{
               "cc" => [_],
               "published" => "2026-10-24T09:00:00Z",
               "extension" => "an extension field",
               "object" => %{"id" => follow_id, "state" => "accept"}
             } = stored(received["id"])

      assert follow_id == context.follow_id
    end

    test "a Reject keeps what its author wrote, with the id of our Follow as its object",
         context do
      received = answer("Reject", context)
      assert {:ok, _} = delivered(received)

      assert %{
               "cc" => [_],
               "published" => "2026-10-24T09:00:00Z",
               "extension" => "an extension field",
               "object" => follow_id
             } = stored(received["id"])

      assert follow_id == context.follow_id
    end
  end

  for type <- ["Like", "Announce"] do
    describe "a received #{type}" do
      test "keeps what its author wrote", context do
        followers = "#{context.other_id}/followers"

        received =
          interaction(unquote(type), context, %{
            "to" => [@public],
            "cc" => [followers],
            "published" => "2026-10-24T09:00:00Z",
            "extension" => "an extension field"
          })

        assert {:ok, _} = delivered(received)

        assert %{
                 "id" => id,
                 "to" => [@public],
                 "cc" => [^followers],
                 "published" => "2026-10-24T09:00:00Z",
                 "extension" => "an extension field"
               } = stored(received["id"])

        assert id == received["id"]
      end

      test "keeps the id of what it is about as its object, not an object embedded in it",
           context do
        embedded = %{"id" => context.note_id, "type" => "Note", "content" => "<p>claimed</p>"}
        received = interaction(unquote(type), context, %{"to" => [@public], "object" => embedded})

        assert {:ok, _} = delivered(received)

        assert stored(received["id"])["object"] == context.note_id
      end
    end
  end
end
