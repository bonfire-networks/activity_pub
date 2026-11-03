defmodule ActivityPub.Federator.Transformer.ObjectReplacementTest do
  @moduledoc """
  An object we already hold can arrive again, from another delivery, a relay or a fetch. Which copy stays:

    * a copy held signed by its author is replaced only by one signed by its owner, of the same type and owner, and provably newer
    * a copy somebody vouched for replaces one nobody did unless it is provably older (by `updated`, else `published`), and one somebody did only when provably newer
    * a copy nobody vouched for never replaces one somebody did, and replaces another such copy only when it is provably newer (its date later)
    * an `Update` is outside this rule, and keeps the behaviour it had
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Object

  @public "https://www.w3.org/ns/activitystreams#Public"
  @t0 "2026-10-01T10:00:00Z"
  @t1 "2026-10-02T10:00:00Z"
  @t2 "2026-10-03T10:00:00Z"

  setup do
    Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    n = System.unique_integer([:positive])
    id = "https://sender-#{n}.example/users/sender"
    key = new_key(:ed25519)
    actor(ap_id: id, data: %{"assertionMethod" => [multikey(id, key)]})

    %{sender: id, key: key, note_id: "#{id}/notes/#{n}"}
  end

  # a remote actor with a key of its own, on `host`
  defp new_actor(host, name) do
    id = "https://#{host}/users/#{name}"
    actor(ap_id: id, data: %{"assertionMethod" => [multikey(id, new_key(:ed25519))]})
    id
  end

  # a Create by `by` of the note, which `owner` is the author of
  defp create_by(by, owner, note_id, content, dates),
    do: put_in(create(by, note_id, content, dates), ["object", "attributedTo"], owner)

  # a group passing a document on, as it reaches us: an Announce by the group, which came in with a verified HTTP signature
  defp relayed(document, group_id) do
    announce = %{
      "type" => "Announce",
      "id" => "#{group_id}/activities/announce/#{System.unique_integer([:positive])}",
      "actor" => group_id,
      "to" => [@public],
      "object" => document
    }

    Transformer.handle_incoming(announce,
      from_inbox: true,
      authenticated: :http_signature,
      signed_by: group_id
    )
  end

  # a Create of the note, with a fresh activity id each time (the same note arriving again, not the same activity)
  defp create(sender, note_id, content, dates) do
    n = System.unique_integer([:positive])

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{sender}/activities/#{n}",
      "type" => "Create",
      "actor" => sender,
      "to" => [@public],
      "object" =>
        %{
          "id" => note_id,
          "type" => "Note",
          "attributedTo" => sender,
          "content" => content,
          "to" => [@public]
        }
        |> Map.merge(dates)
    }
  end

  defp vouched(document, sender),
    do:
      Transformer.handle_incoming(document,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: sender
      )

  defp not_vouched(document), do: Transformer.handle_incoming(document, from_inbox: true)

  defp row(ap_id) do
    {:ok, %Object{id: id}} = Object.get_cached(ap_id: ap_id)
    ActivityPub.Utils.repo().get!(Object, id)
  end

  defp content(ap_id), do: row(ap_id).data["content"]

  describe "a copy somebody vouched for" do
    test "replaces one nobody vouched for", %{sender: sender, note_id: note_id} do
      assert {:ok, _} = not_vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}))
      assert row(note_id).authenticated == :unverified

      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v2</p>", %{"published" => @t0}), sender)

      assert content(note_id) == "<p>v2</p>"
      assert row(note_id).authenticated == :http_signature
    end

    test "replaces an earlier vouched one, though not vouched the same way", %{
      sender: sender,
      note_id: note_id
    } do
      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}), sender)

      assert {:ok, _} =
               vouched(
                 create(sender, note_id, "<p>v2</p>", %{"published" => @t0, "updated" => @t1}),
                 sender
               )

      assert content(note_id) == "<p>v2</p>"
    end

    # over one somebody vouched for too, only a provably newer copy: an older copy replayed in a fresh envelope, by a relay or anyone holding it, must not put back what an edit replaced, and with nothing to tell them apart the one we hold stays
    test "keeps the stored one when the dates are equal", %{sender: sender, note_id: note_id} do
      assert {:ok, _} = vouched(create(sender, note_id, "<p>v1</p>", %{"updated" => @t1}), sender)
      vouched(create(sender, note_id, "<p>v2</p>", %{"updated" => @t1}), sender)

      assert content(note_id) == "<p>v1</p>"
    end

    test "keeps the stored one when neither has a date", %{sender: sender, note_id: note_id} do
      assert {:ok, _} = vouched(create(sender, note_id, "<p>v1</p>", %{}), sender)
      vouched(create(sender, note_id, "<p>v2</p>", %{}), sender)

      assert content(note_id) == "<p>v1</p>"
    end

    test "is refused when it is provably older", %{sender: sender, note_id: note_id} do
      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v2</p>", %{"updated" => @t2}), sender)

      vouched(create(sender, note_id, "<p>v1</p>", %{"updated" => @t1}), sender)

      assert content(note_id) == "<p>v2</p>"
    end

    test "a Create delivered again after an Update does not put the old content back", %{
      sender: sender,
      note_id: note_id
    } do
      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}), sender)

      update = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{sender}/activities/update-#{System.unique_integer([:positive])}",
        "type" => "Update",
        "actor" => sender,
        "to" => [@public],
        "object" =>
          create(sender, note_id, "<p>v2, edited</p>", %{"published" => @t0, "updated" => @t2})[
            "object"
          ]
      }

      assert {:ok, _} = vouched(update, sender)
      assert content(note_id) == "<p>v2, edited</p>"

      # the original Create arrives again, as a relay or a retry would send it
      vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}), sender)

      assert content(note_id) == "<p>v2, edited</p>"
    end

    # an Update is new to us by its id, so an older version of the object, the owner's own and signed, can be wrapped in a fresh one: it must not revert the edit, whoever re-sends it
    test "an Update carrying an older version than the one we hold does not revert the edit", %{
      sender: sender,
      key: key,
      note_id: note_id
    } do
      update_with = fn object ->
        %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => "#{sender}/activities/update-#{System.unique_integer([:positive])}",
          "type" => "Update",
          "actor" => sender,
          "to" => [@public],
          "object" => object
        }
      end

      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}), sender)

      edited =
        create(sender, note_id, "<p>v2, edited</p>", %{"published" => @t0, "updated" => @t2})[
          "object"
        ]

      assert {:ok, _} = vouched(update_with.(edited), sender)
      assert content(note_id) == "<p>v2, edited</p>", "control: the edit applies"

      older =
        create(sender, note_id, "<p>v1, replayed</p>", %{"published" => @t0, "updated" => @t1})[
          "object"
        ]
        |> Map.put("@context", [
          "https://www.w3.org/ns/activitystreams",
          "https://w3id.org/security/data-integrity/v2"
        ])
        |> sign(key)

      Transformer.handle_incoming(update_with.(older),
        from_inbox: true,
        authenticated: :integrity_proof,
        signed_by: sender
      )

      assert content(note_id) == "<p>v2, edited</p>"
    end
  end

  # A copy we hold signed by its author (its proof kept, `data_received`) is rewritten only by another copy signed by its owner, of the same type and owner, and provably newer: a server that changes hands (an expired domain re-registered) or just goes on serving something else can't put words in the author's mouth with an unsigned copy, by delivery or refetch. Deletion is not this rule's: it is honoured as before
  describe "a copy we hold signed by its author" do
    # over a verified HTTP signature with the Create's proof, as the receiver worker gets it: what keeps the original
    defp received(document, signer) do
      ActivityPub.Federator.Worker.ReceiverHelpers.perform(
        %Oban.Job{
          args: %{
            "op" => "incoming_ap_doc",
            "params" => document,
            "signed_by" => signer,
            "repo" => ActivityPub.Utils.repo()
          }
        },
        :verified
      )
    end

    defp signed_create(sender, key, note_id, content, dates, type \\ "Note") do
      %{"object" => note} = create = create(sender, note_id, content, dates)

      note =
        note
        |> Map.put("type", type)
        |> Map.put("@context", [
          "https://www.w3.org/ns/activitystreams",
          "https://w3id.org/security/data-integrity/v2"
        ])
        |> sign(key)

      create
      |> Map.put("@context", [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/data-integrity/v2"
      ])
      |> Map.put("object", note)
      |> sign(key)
    end

    defp held(note_id) do
      {:ok, object} = Object.get_uncached(ap_id: note_id)
      object
    end

    setup %{sender: sender, key: key, note_id: note_id} do
      assert {:ok, _} =
               received(
                 signed_create(sender, key, note_id, "<p>v1</p>", %{"updated" => @t1}),
                 sender
               )

      assert %{"proof" => _} = held(note_id).data_received, "control: held signed"
      :ok
    end

    test "is not rewritten by a newer copy its owner's server sends unsigned", %{
      sender: sender,
      note_id: note_id
    } do
      vouched(create(sender, note_id, "<p>v2, unsigned</p>", %{"updated" => @t2}), sender)

      assert held(note_id).data["content"] == "<p>v1</p>"
    end

    test "is not rewritten by a newer unsigned copy fetched from its origin", %{
      sender: sender,
      note_id: note_id
    } do
      newer = create(sender, note_id, "<p>v2, fetched</p>", %{"updated" => @t2})["object"]

      Tesla.Mock.mock(fn
        %{method: :get, url: ^note_id} -> Tesla.Mock.json(newer)
        %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      end)

      ActivityPub.Federator.Fetcher.fetch_fresh_object_from_id(note_id)

      assert held(note_id).data["content"] == "<p>v1</p>"
    end

    test "stays as it is when its origin can't be reached, or answers 404", %{note_id: note_id} do
      for answer <- [{:error, :nxdomain}, %Tesla.Env{status: 404, body: ""}] do
        Tesla.Mock.mock(fn %{method: :get} -> answer end)
        ActivityPub.Federator.Fetcher.fetch_fresh_object_from_id(note_id)

        assert %{"proof" => _} = held(note_id).data_received
        assert held(note_id).data["content"] == "<p>v1</p>"
      end
    end

    test "is not rewritten by a newer signed copy of another type", %{
      sender: sender,
      key: key,
      note_id: note_id
    } do
      received(
        signed_create(
          sender,
          key,
          note_id,
          "<p>v2, as an article</p>",
          %{"updated" => @t2},
          "Article"
        ),
        sender
      )

      assert held(note_id).data["content"] == "<p>v1</p>"
      assert held(note_id).data["type"] == "Note"
    end

    # the control: what may rewrite it
    test "is rewritten by a newer copy signed by its owner", %{
      sender: sender,
      key: key,
      note_id: note_id
    } do
      assert {:ok, _} =
               received(
                 signed_create(sender, key, note_id, "<p>v2, signed</p>", %{"updated" => @t2}),
                 sender
               )

      assert held(note_id).data["content"] == "<p>v2, signed</p>"
    end
  end

  describe "a copy nobody vouched for" do
    test "does not replace one somebody vouched for", %{sender: sender, note_id: note_id} do
      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}), sender)

      not_vouched(
        create(sender, note_id, "<p>forged</p>", %{"published" => @t0, "updated" => @t2})
      )

      assert content(note_id) == "<p>v1</p>"
      assert row(note_id).authenticated == :http_signature
    end

    test "replaces another copy nobody vouched for when it is provably newer", %{
      sender: sender,
      note_id: note_id
    } do
      assert {:ok, _} = not_vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}))

      not_vouched(create(sender, note_id, "<p>v2</p>", %{"published" => @t0, "updated" => @t1}))

      assert content(note_id) == "<p>v2</p>"
      assert row(note_id).authenticated == :unverified
    end

    test "does not replace another copy nobody vouched for with the same date, or none", %{
      sender: sender,
      note_id: note_id
    } do
      assert {:ok, _} = not_vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}))

      not_vouched(create(sender, note_id, "<p>v2</p>", %{"published" => @t0}))
      assert content(note_id) == "<p>v1</p>", "the same date says nothing about which is later"

      not_vouched(create(sender, note_id, "<p>v3</p>", %{}))
      assert content(note_id) == "<p>v1</p>", "no date on the new copy says nothing either"
    end

    test "does not replace another copy nobody vouched for with an older one", %{
      sender: sender,
      note_id: note_id
    } do
      assert {:ok, _} = not_vouched(create(sender, note_id, "<p>v2</p>", %{"updated" => @t2}))

      not_vouched(create(sender, note_id, "<p>v1</p>", %{"updated" => @t1}))

      assert content(note_id) == "<p>v2</p>"
    end
  end

  # Whose copy it is matters as much as how well it is vouched for: a copy of somebody's object, sent by somebody else, is not theirs to put in the place of what we hold. Only the object's owner (or a relay carrying the owner's own signature) replaces it
  describe "a copy from somebody who does not own the object" do
    setup %{sender: sender} do
      n = System.unique_integer([:positive])

      %{
        other: new_actor("other-#{n}.example", "mallory"),
        same_host: new_actor(URI.parse(sender).host, "mallory-#{n}"),
        group: insert(:actor).data["id"]
      }
    end

    test "sent by another actor, signed as itself, does not replace one nobody vouched for", %{
      sender: sender,
      other: other,
      note_id: note_id
    } do
      assert {:ok, _} = not_vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}))

      vouched(
        create_by(other, sender, note_id, "<p>forged</p>", %{
          "published" => @t0,
          "updated" => @t2
        }),
        other
      )

      assert content(note_id) == "<p>v1</p>"
      assert row(note_id).authenticated == :unverified
    end

    test "sent by another account on the owner's host, naming itself the author, does not replace even a vouched one",
         %{sender: sender, same_host: mallory, note_id: note_id} do
      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}), sender)

      vouched(create(mallory, note_id, "<p>forged</p>", %{}), mallory)

      assert content(note_id) == "<p>v1</p>"
      assert row(note_id).authenticated == :http_signature
    end

    test "naming the owner as its actor, but relayed by a group with nothing vouching for it, does not replace one nobody vouched for",
         %{sender: sender, group: group, note_id: note_id} do
      assert {:ok, _} = not_vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}))

      relayed(
        create(sender, note_id, "<p>forged</p>", %{"published" => @t0, "updated" => @t2}),
        group
      )

      assert content(note_id) == "<p>v1</p>"
    end

    # the other side of the three above: what is allowed, so a refusal is the check and not a replacement that never works
    test "carrying the owner's own proof, though a group relays it, replaces", %{
      sender: sender,
      key: key,
      group: group,
      note_id: note_id
    } do
      assert {:ok, _} = not_vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}))

      signed =
        create(sender, note_id, "<p>v2</p>", %{"published" => @t0, "updated" => @t1})
        |> Map.put("@context", [
          "https://www.w3.org/ns/activitystreams",
          "https://w3id.org/security/data-integrity/v2"
        ])
        |> sign(key)

      assert {:ok, _} = relayed(signed, group)

      assert content(note_id) == "<p>v2</p>"
      assert row(note_id).authenticated == :integrity_proof
    end

    test "the owner's own unsigned copy, delivered directly, still replaces one nobody vouched for",
         %{sender: sender, note_id: note_id} do
      assert {:ok, _} = not_vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}))

      not_vouched(create(sender, note_id, "<p>v2</p>", %{"published" => @t0, "updated" => @t1}))

      assert content(note_id) == "<p>v2</p>"
    end
  end

  test "the same copy arriving again changes nothing", %{sender: sender, note_id: note_id} do
    assert {:ok, _} = vouched(create(sender, note_id, "<p>v1</p>", %{"updated" => @t1}), sender)
    before = row(note_id)

    vouched(create(sender, note_id, "<p>v1</p>", %{"updated" => @t1}), sender)

    assert row(note_id).data == before.data
    assert row(note_id).updated_at == before.updated_at
  end
end
