defmodule ActivityPub.Federator.Transformer.NestedObjectsAtIngestTest do
  @moduledoc """
  An object nested in a field of a delivered `Create`'s object (an event's `location`) is stored as an object of its own when the `Create` is ingested, without asking its origin, and the field keeps its AP id. The copy stored is the embedded one, so it is `unverified`: the delivery's signature covers the `Create`, not what it carries.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Object

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    n = System.unique_integer([:positive])
    id = "https://sender-#{n}.example/users/sender"
    key = new_key(:ed25519)
    actor(ap_id: id, data: %{"assertionMethod" => [multikey(id, key)]})

    test_pid = self()

    Tesla.Mock.mock(fn %{method: :get, url: url} ->
      send(test_pid, {:fetched, url})
      %Tesla.Env{status: 404, body: ""}
    end)

    %{n: n, sender: %{id: id, key: key}}
  end

  # the @context is on the Create, as real documents have it; the Event inside has none
  defp create_of_event(sender, fields) do
    n = System.unique_integer([:positive])

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{sender.id}/activities/#{n}",
      "type" => "Create",
      "actor" => sender.id,
      "to" => [@public],
      "object" =>
        Map.merge(
          %{
            "id" => "#{sender.id}/events/#{n}",
            "type" => "Event",
            "attributedTo" => sender.id,
            "name" => "an event",
            "to" => [@public]
          },
          fields
        )
    }
  end

  defp place(sender) do
    %{
      "id" => "https://venue-#{System.unique_integer([:positive])}.example/places/1",
      "type" => "Place",
      "name" => "a venue"
    }
  end

  defp row(ap_id) do
    {:ok, %Object{id: id}} = Object.get_cached(ap_id: ap_id)
    ActivityPub.Utils.repo().get!(Object, id)
  end

  test "stores the nested object on its own and leaves its id in the field", %{sender: sender} do
    venue = place(sender)
    create = create_of_event(sender, %{"location" => venue})

    assert {:ok, _} =
             Transformer.handle_incoming(create,
               from_inbox: true,
               authenticated: :http_signature,
               signed_by: sender.id
             )

    assert row(create["object"]["id"]).data["location"] == venue["id"]
    assert row(venue["id"]).data["name"] == "a venue"
  end

  test "does not ask the nested object's origin", %{sender: sender} do
    venue = place(sender)
    venue_id = venue["id"]
    create = create_of_event(sender, %{"location" => venue})

    assert {:ok, _} =
             Transformer.handle_incoming(create,
               from_inbox: true,
               authenticated: :http_signature,
               signed_by: sender.id
             )

    refute_received {:fetched, ^venue_id}
  end

  test "stores the nested object as unverified, though the delivery was signed", %{sender: sender} do
    venue = place(sender)
    create = create_of_event(sender, %{"location" => venue})

    assert {:ok, _} =
             Transformer.handle_incoming(create,
               from_inbox: true,
               authenticated: :http_signature,
               signed_by: sender.id
             )

    assert row(venue["id"]).authenticated == :unverified
    assert row(create["object"]["id"]).authenticated == :http_signature
  end

  # A nested object is vouched for by its own proof, by its owner being the sender, or by its id being on the sender's host with any owner it names there too (FEP-fe34). One nobody vouched for that NAMES an owner would be a post in that owner's name on the sender's word, so it is not stored, and the field keeps its id for whoever needs it to fetch from its origin; one that names no owner is stored unverified, credited to the sender who asserted it
  describe "a nested object nobody vouched for" do
    setup %{n: n} do
      victim = "https://victim-#{n}.example/users/victim"
      actor(ap_id: victim)
      %{victim: victim}
    end

    defp deliver(create, sender),
      do:
        Transformer.handle_incoming(create,
          from_inbox: true,
          authenticated: :http_signature,
          signed_by: sender.id
        )

    defp note(id, owner) do
      %{"id" => id, "type" => "Note", "content" => "<p>words</p>", "to" => [@public]}
      |> then(&if(owner, do: Map.put(&1, "attributedTo", owner), else: &1))
    end

    defp stored?(ap_id), do: match?({:ok, %Object{}}, Object.get_cached(ap_id: ap_id))

    test "naming someone else as its owner, on their host, is not stored", %{
      sender: sender,
      victim: victim
    } do
      forged = note("#{victim}/notes/forged", victim)
      create = create_of_event(sender, %{"location" => forged})

      assert {:ok, _} = deliver(create, sender)

      assert row(create["object"]["id"]).data["location"] == forged["id"],
             "the field keeps its id"

      refute stored?(forged["id"]), "stored a post in someone else's name on the sender's word"
    end

    test "naming someone else as its owner, on the sender's host, is not stored", %{
      sender: sender,
      victim: victim
    } do
      forged = note("#{sender.id}/notes/forged", victim)
      create = create_of_event(sender, %{"location" => forged})

      assert {:ok, _} = deliver(create, sender)

      refute stored?(forged["id"]),
             "the sender's host vouched for an object it says is someone else's"
    end

    test "naming no owner is stored unverified, credited to the sender, not to us", %{
      sender: sender
    } do
      ownerless =
        note("https://elsewhere-#{System.unique_integer([:positive])}.example/notes/1", nil)

      create = create_of_event(sender, %{"location" => ownerless})

      assert {:ok, _} = deliver(create, sender)

      assert row(ownerless["id"]).authenticated == :unverified

      assert %Object{data: %{"actor" => actor}} =
               Object.get_activity_for_object_ap_id(ownerless["id"])

      assert Object.get_ap_id(actor) == sender.id, "credited to our service actor, not the sender"
    end

    # the controls: what is vouched for is stored
    test "control: one owned by the sender, or carrying its owner's proof, is stored", %{
      sender: sender,
      n: n
    } do
      own = note("#{sender.id}/notes/own", sender.id)
      author = "https://author-#{n}.example/users/author"
      key = new_key(:ed25519)
      actor(ap_id: author, data: %{"assertionMethod" => [multikey(author, key)]})
      signed = note("#{author}/notes/signed", author) |> sign(key)

      assert {:ok, _} = deliver(create_of_event(sender, %{"location" => own}), sender)
      assert {:ok, _} = deliver(create_of_event(sender, %{"location" => signed}), sender)

      assert stored?(own["id"])
      assert stored?(signed["id"])
    end
  end

  # The same for a document we fetched: its origin answers for what is on its own host, not for what it says is someone else's elsewhere
  describe "a nested object in a document we fetched" do
    setup %{n: n} do
      origin = "https://origin-#{n}.example"
      author = "#{origin}/users/author"
      actor(ap_id: author)
      victim = "https://victim-#{n}.example/users/victim"
      actor(ap_id: victim)
      %{origin: origin, author: author, victim: victim}
    end

    defp fetched_note(c, location) do
      note_id = "#{c.origin}/notes/#{System.unique_integer([:positive])}"

      note = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => note_id,
        "type" => "Note",
        "attributedTo" => c.author,
        "content" => "<p>fetched</p>",
        "to" => [@public],
        "location" => location
      }

      Tesla.Mock.mock(fn
        %{method: :get, url: ^note_id} -> Tesla.Mock.json(note)
        %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      end)

      assert {:ok, _} = ActivityPub.Federator.Fetcher.fetch_object_from_id(note_id)
      note_id
    end

    test "one claiming to be someone else's elsewhere is not stored", %{victim: victim} = c do
      forged = %{
        "id" => "#{victim}/notes/forged",
        "type" => "Note",
        "attributedTo" => victim,
        "content" => "<p>forged</p>",
        "to" => [@public]
      }

      note_id = fetched_note(c, forged)

      assert row(note_id).data["location"] == forged["id"], "control: the fetched note is stored"
      refute match?({:ok, %Object{}}, Object.get_cached(ap_id: forged["id"]))
    end

    test "control: one its author owns on the same host is stored",
         %{author: author, origin: origin} = c do
      own = %{
        "id" => "#{origin}/notes/own-#{System.unique_integer([:positive])}",
        "type" => "Note",
        "attributedTo" => author,
        "content" => "<p>theirs</p>",
        "to" => [@public]
      }

      fetched_note(c, own)

      assert match?({:ok, %Object{}}, Object.get_cached(ap_id: own["id"]))
    end
  end

  test "does the same for the object of an Update", %{sender: sender} do
    create = create_of_event(sender, %{})

    assert {:ok, _} =
             Transformer.handle_incoming(create,
               from_inbox: true,
               authenticated: :http_signature,
               signed_by: sender.id
             )

    venue = place(sender)

    update = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{sender.id}/activities/update-#{System.unique_integer([:positive])}",
      "type" => "Update",
      "actor" => sender.id,
      "to" => [@public],
      "object" => Map.put(create["object"], "location", venue)
    }

    assert {:ok, _} =
             Transformer.handle_incoming(update,
               from_inbox: true,
               authenticated: :http_signature,
               signed_by: sender.id
             )

    assert row(create["object"]["id"]).data["location"] == venue["id"]
    assert row(venue["id"]).data["name"] == "a venue"
    assert row(venue["id"]).authenticated == :unverified
  end

  test "leaves a field its context does not define as an IRI alone", %{sender: sender} do
    venue = place(sender)
    create = create_of_event(sender, %{"somethingElse" => venue})

    assert {:ok, _} =
             Transformer.handle_incoming(create,
               from_inbox: true,
               authenticated: :http_signature,
               signed_by: sender.id
             )

    assert row(create["object"]["id"]).data["somethingElse"]["id"] == venue["id"]
    assert {:error, :not_found} = Object.get_cached(ap_id: venue["id"])
  end

  test "leaves a nested object with no id embedded", %{sender: sender} do
    anonymous = %{"type" => "Place", "name" => "somewhere"}
    create = create_of_event(sender, %{"location" => anonymous})

    assert {:ok, _} =
             Transformer.handle_incoming(create,
               from_inbox: true,
               authenticated: :http_signature,
               signed_by: sender.id
             )

    assert row(create["object"]["id"]).data["location"]["name"] == "somewhere"
  end
end
