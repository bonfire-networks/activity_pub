defmodule ActivityPub.Federator.RelayedReceivedDocumentTest do
  @moduledoc """
  What the library sends when a group announces somebody else's activity (`ActivityPub.announce/2` with an activity as its object). A follower elsewhere can rely on the author's activity inside only if the author's proof still verifies there, so the inner activity must go out byte for byte as the author sent it.

  Which activities a group announces, and when, is the adapter's decision (in Bonfire, `AdapterUtils.announce_by_group/2`), tested there; this calls `ActivityPub.announce/2` the way it does.

  The first block pins what goes out without the received document, built from the stored copy, which is what is sent today.
  """
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()
  use Repatch.ExUnit

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias ActivityPub.Federator.APPublisher
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Federator.Workers.PublisherWorker
  alias ActivityPub.Safety.IntegrityProofs
  alias ActivityPub.Tests.ObanHelpers

  @public "https://www.w3.org/ns/activitystreams#Public"
  @context [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/data-integrity/v2"
  ]

  setup do
    n = System.unique_integer([:positive])

    key = new_key(:ed25519)
    author_id = "https://author-#{n}.example/users/author"
    actor(ap_id: author_id, data: %{"assertionMethod" => [multikey(author_id, key)]})

    follower = remote_actor("https://follower-#{n}.example", "follower")
    other_follower = remote_actor("https://other-#{n}.example", "follower")

    %{username: username} = local_actor()
    {:ok, local} = Actor.get_cached(username: username)
    group = %{local | data: Map.put(local.data, "type", "Group")}

    # both follow the group, so what it announces is published to them
    for f <- [follower, other_follower], do: assert({:ok, _} = follows(f, local))

    # the author's post, as delivered
    create = author_id |> create_note() |> sign(key)
    assert {:ok, _} = delivered(create, author_id)

    %{
      key: key,
      author_id: author_id,
      group: group,
      follower: follower,
      other_follower: other_follower,
      note: create["object"]
    }
  end

  # its own shared inbox, so each follower is a delivery of its own
  defp remote_actor(origin, name),
    do: actor(ap_id: "#{origin}/users/#{name}", shared_inbox: "#{origin}/inbox")

  defp follows(follower, followed) do
    delivered(
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{follower.ap_id}/follows/#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => follower.ap_id,
        "object" => followed.data["id"]
      },
      follower.ap_id
    )
  end

  defp delivered(document, signer),
    do:
      Transformer.handle_incoming(document,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: signer
      )

  # the author's edit of the post, embedding the post as edited, signed by the author
  defp signed_update(%{author_id: author_id, key: key, note: note}) do
    %{
      "@context" => @context,
      "id" => "#{author_id}/activities/update-#{System.unique_integer([:positive])}",
      "type" => "Update",
      "actor" => author_id,
      "to" => [@public],
      "object" =>
        note |> Map.put("content", "<p>edited</p>") |> Map.put("updated", "2026-10-24T12:00:00Z")
    }
    |> sign(key)
  end

  defp signed_like(%{author_id: author_id, key: key, note: note}) do
    %{
      "@context" => @context,
      "id" => "#{author_id}/activities/like-#{System.unique_integer([:positive])}",
      "type" => "Like",
      "actor" => author_id,
      "to" => [@public],
      "object" => note["id"]
    }
    |> sign(key)
  end

  # the group announces the stored activity, to the follower
  defp group_payloads(%{group: group, follower: follower} = context, %{"type" => type}) do
    # found through the post it is about, as the group finds it
    stored = Object.get_activity_for_object_ap_id(context.note["id"], type)

    assert %Object{data: %{"type" => ^type}} = stored

    {:ok, announce} =
      ActivityPub.announce(%{actor: group, object: stored}, skip_public_check: true)

    announce = %{
      announce
      | data: Map.update(announce.data, "cc", [follower.ap_id], &[follower.ap_id | &1])
    }

    group
    |> APPublisher.prepare_publish_params(announce)
    |> Enum.map(&Jason.decode!(&1.json))
  end

  describe "without the received document (as today)" do
    test "an Update goes out rebuilt from the stored copy, and the author's proof no longer verifies",
         context do
      update = signed_update(context)
      assert {:ok, _} = delivered(update, context.author_id)

      payloads = group_payloads(context, update)
      assert payloads != []

      for %{"type" => "Announce", "object" => inner} <- payloads do
        assert inner["type"] == "Update"
        assert is_map(inner["object"]), "the post is embedded again on the way out"
        refute inner == update
        refute IntegrityProofs.verify(inner) == {:ok, context.author_id}
      end
    end

    test "a Like goes out with the liked post embedded, and the author's proof no longer verifies",
         context do
      like = signed_like(context)
      assert {:ok, _} = delivered(like, context.author_id)

      payloads = group_payloads(context, like)
      assert payloads != []

      for %{"type" => "Announce", "object" => inner} <- payloads do
        assert inner["type"] == "Like"

        assert is_map(inner["object"]),
               "the author sent an id, the Announce clause embeds the post"

        refute inner == like
        refute IntegrityProofs.verify(inner) == {:ok, context.author_id}
      end
    end
  end

  # The real path: `ActivityPub.announce/2` stores the Announce and queues its publish job, which reloads it by id; running that job queues one delivery per inbox. What each inbox is sent, by inbox.
  defp published(%{group: group} = context, %{"type" => type}, opts, as_handed_on \\ & &1) do
    stored = Object.get_activity_for_object_ap_id(context.note["id"], type) |> as_handed_on.()

    {:ok, announce} =
      ActivityPub.announce(%{actor: group, object: stored}, [skip_public_check: true] ++ opts)

    all_enqueued(worker: PublisherWorker)
    |> Enum.filter(&(&1.args["op"] == "publish" and &1.args["activity_id"] == announce.id))
    |> ObanHelpers.perform()

    for %{args: %{"op" => "publish_one", "params" => params}} <-
          all_enqueued(worker: PublisherWorker),
        %{"type" => "Announce", "actor" => actor} = json = Jason.decode!(params["json"]),
        actor == group.data["id"],
        into: %{},
        do: {params["inbox"], json}
  end

  defp inners(published), do: published |> Map.values() |> Enum.map(& &1["object"])

  # the row as stored, past the cache
  defp row(ap_id) do
    {:ok, %Object{id: id}} = Object.get_cached(ap_id: ap_id)
    ActivityPub.Utils.repo().get!(Object, id)
  end

  describe "accepted by its HTTP signature, its proof is checked when the group relays it" do
    test "a valid one: relayed as received, and the Update and its post are then stored as integrity_proof",
         context do
      update = signed_update(context)
      assert {:ok, _} = delivered(update, context.author_id)
      assert row(update["id"]).authenticated == :http_signature

      for inner <- inners(published(context, update, data_received: update)),
          do: assert(inner == update)

      assert row(update["id"]).authenticated == :integrity_proof

      assert row(context.note["id"]).authenticated == :integrity_proof,
             "the post is the author's, so the proof covers it too"
    end

    test "a broken one: the copy we stored goes instead, and nothing is upgraded", context do
      # a signature that does not hold has the author's key fetched again, in case it changed
      Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

      update = signed_update(context) |> Map.put("summary", "changed after it was signed")
      assert {:ok, _} = delivered(update, context.author_id)

      for inner <- inners(published(context, update, data_received: update)) do
        refute inner == update

        refute Map.has_key?(inner, "proof"),
               "a follower refuses a broken proof, where it accepts none"
      end

      assert row(update["id"]).authenticated == :http_signature
    end

    test "a valid one is then stored with the activity, as it arrived", context do
      update = signed_update(context)
      assert {:ok, _} = delivered(update, context.author_id)
      assert row(update["id"]).data_received == nil

      published(context, update, data_received: update)

      assert row(update["id"]).data_received == update
    end

    test "one accepted by its proof is not checked again", context do
      update = signed_update(context)

      assert {:ok, _} =
               Transformer.handle_incoming(update,
                 from_inbox: true,
                 authenticated: :integrity_proof,
                 signed_by: context.author_id
               )

      test_pid = self()

      Repatch.patch(IntegrityProofs, :check, [mode: :shared], fn document, opts ->
        send(test_pid, :checked)
        Repatch.real(IntegrityProofs.check(document, opts))
      end)

      for inner <- inners(published(context, update, data_received: update)),
          do: assert(inner == update)

      refute_received :checked
    end
  end

  describe "with the received document" do
    test "an Update goes out exactly as the author sent it, and the author's proof verifies",
         context do
      update = signed_update(context)
      assert {:ok, _} = delivered(update, context.author_id)

      published = published(context, update, data_received: update)
      assert map_size(published) == 2, "one delivery per follower"

      for {_inbox, announce} <- published do
        assert announce["object"] == update
        assert IntegrityProofs.verify(announce["object"]) == {:ok, context.author_id}
        assert IntegrityProofs.verify(announce) == {:ok, context.group.data["id"]}
      end
    end

    test "a Like goes out with the post as an id, as the author sent it, and its proof verifies",
         context do
      like = signed_like(context)
      assert {:ok, _} = delivered(like, context.author_id)

      for inner <- inners(published(context, like, data_received: like)) do
        assert inner == like
        assert IntegrityProofs.verify(inner) == {:ok, context.author_id}
      end
    end

    # The adapter no longer puts the delivery's document on the activity it hands over (`received_document_handover_test.exs`): an activity's original is the one stored with its row, so a struct carrying one its row does not hold is not a shape anything makes. Superseded by "a stored original is relayed with nothing handed on" below.
    # test "is found on the announced activity itself, as the adapter hands it on", context do
    #   update = signed_update(context)
    #   assert {:ok, _} = delivered(update, context.author_id)
    #
    #   for inner <- inners(published(context, update, [], &%{&1 | data_received: update})) do
    #     assert inner == update
    #     assert IntegrityProofs.verify(inner) == {:ok, context.author_id}
    #   end
    # end

    test "the publish job carries no copy of it: the original is read from the row, so a retry sends it too",
         context do
      update = signed_update(context)
      assert {:ok, _} = delivered(update, context.author_id)

      stored = Object.get_activity_for_object_ap_id(context.note["id"], "Update")

      {:ok, announce} =
        ActivityPub.announce(%{actor: context.group, object: stored},
          skip_public_check: true,
          data_received: update
        )

      # the job as queued, before it runs
      assert [job] =
               all_enqueued(worker: PublisherWorker)
               |> Enum.filter(
                 &(&1.args["op"] == "publish" and &1.args["activity_id"] == announce.id)
               )

      refute Map.has_key?(job.args, "data_received")

      ObanHelpers.perform([job])

      inners =
        for %{args: %{"op" => "publish_one", "params" => params}} <-
              all_enqueued(worker: PublisherWorker),
            %{"type" => "Announce", "object" => inner} <- [Jason.decode!(params["json"])],
            do: inner

      assert length(inners) == 2
      for inner <- inners, do: assert(inner == update)
    end

    test "a stored original is relayed with nothing handed on, as when the group approves a post later",
         context do
      update = signed_update(context)

      # delivered through the receiver, whose proof check keeps the original with the row
      assert {:ok, _} =
               ActivityPub.Federator.Worker.ReceiverHelpers.perform(
                 %Oban.Job{
                   args: %{
                     "op" => "incoming_ap_doc",
                     "params" => update,
                     "signed_by" => context.author_id,
                     "repo" => ActivityPub.Utils.repo()
                   }
                 },
                 :verified
               )

      for inner <- inners(published(context, update, [])) do
        assert inner == update
        assert IntegrityProofs.verify(inner) == {:ok, context.author_id}
      end
    end

    test "each inbox gets the same inner copy", context do
      update = signed_update(context)
      assert {:ok, _} = delivered(update, context.author_id)

      assert [one, two] = inners(published(context, update, data_received: update))
      assert one == two
    end

    test "one with no proof or signature of its own is not used", context do
      like = signed_like(context)
      assert {:ok, _} = delivered(like, context.author_id)

      for inner <- inners(published(context, like, data_received: Map.delete(like, "proof"))) do
        assert is_map(inner["object"]), "built from the stored copy, as without one"
      end
    end

    test "one with another id is not used", context do
      like = signed_like(context)
      assert {:ok, _} = delivered(like, context.author_id)

      other = Map.put(like, "id", like["id"] <> "-other")

      for inner <- inners(published(context, like, data_received: other)) do
        assert inner["id"] == like["id"]
        assert is_map(inner["object"]), "built from the stored copy, as without one"
      end
    end

    test "one with bto or bcc is relayed as it is too: taking them out is the emitting instance's job (ActivityPub 6.11), and would break the author's proof",
         context do
      hidden = "https://elsewhere.example/users/hidden"

      update =
        signed_update(context)
        |> Map.delete("proof")
        |> Map.put("bcc", [hidden])
        |> sign(context.key)

      assert {:ok, _} = delivered(update, context.author_id)

      for inner <- inners(published(context, update, data_received: update)) do
        assert inner == update
        assert IntegrityProofs.verify(inner) == {:ok, context.author_id}
      end
    end
  end
end
