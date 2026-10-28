defmodule ActivityPub.Federator.NestedObjectsReembedTest do
  @moduledoc """
  An object nested in a field of a delivered object (an event's `location`) is stored on its own at ingest and the field keeps its id. When we send that object on as a copy built from our row (in a `Create`, or inside an `Announce` of it by a group), the author's form is restored: the field holds the nested object again, from the row we hold. Never fetched: one we do not hold stays an id.

  Only for someone else's objects, with the fields ingest looks in when the document has no `@context` of its own (a stored row has lost it): the bundled ActivityStreams terms and the configured ones. A signed document sends its original instead, which is not touched here.
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

  defp place(name \\ "a venue") do
    %{
      "id" => "https://venue-#{System.unique_integer([:positive])}.example/places/1",
      "type" => "Place",
      "name" => name
    }
  end

  defp delivered(document, sender),
    do:
      Transformer.handle_incoming(document,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: sender.id
      )

  # the Create as it goes out
  defp outgoing(create) do
    {:ok, %Object{data: data}} = Object.get_cached(ap_id: create["id"])
    {:ok, out} = Transformer.prepare_outgoing(data)
    out
  end

  # the same inside a group's Announce of it
  defp announced(create) do
    {:ok, %Object{data: data}} = Object.get_cached(ap_id: create["id"])

    {:ok, out} =
      Transformer.prepare_outgoing(%{
        "type" => "Announce",
        "id" => data["id"] <> "#announce",
        "actor" => data["actor"],
        "to" => [@public],
        "object" => data
      })

    out["object"]
  end

  test "a nested object we hold goes out embedded, in the Create and in an Announce of it", %{
    sender: sender
  } do
    venue = place()
    create = create_of_event(sender, %{"location" => venue})
    assert {:ok, _} = delivered(create, sender)

    assert %{"location" => %{"id" => id, "name" => "a venue"}} = outgoing(create)["object"]
    assert id == venue["id"]

    assert %{"location" => %{"id" => ^id, "name" => "a venue"}} = announced(create)["object"]
  end

  test "a nested object we do not hold stays an id, and nothing is fetched", %{sender: sender} do
    venue = place()
    create = create_of_event(sender, %{"location" => venue})
    assert {:ok, _} = delivered(create, sender)

    # pruned since
    ActivityPub.Utils.repo().delete_all(
      Ecto.Query.from(o in Object, where: fragment("?->>'id' = ?", o.data, ^venue["id"]))
    )

    flush_fetches()

    assert outgoing(create)["object"]["location"] == venue["id"]
    refute_received {:fetched, _}
  end

  test "a field the author sent as a plain id stays an id when we hold its object only because we fetched it",
       %{sender: sender} do
    venue = place()

    Tesla.Mock.mock(fn %{method: :get, url: url} ->
      if url == venue["id"],
        do: Tesla.Mock.json(Map.put(venue, "@context", "https://www.w3.org/ns/activitystreams")),
        else: %Tesla.Env{status: 404, body: ""}
    end)

    assert {:ok, _} = ActivityPub.Federator.Fetcher.fetch_object_from_id(venue["id"])

    create = create_of_event(sender, %{"location" => venue["id"]})
    assert {:ok, _} = delivered(create, sender)

    assert outgoing(create)["object"]["location"] == venue["id"]
  end

  test "a list field gets each nested object we hold back in place, and leaves the others", %{
    sender: sender
  } do
    one = place("one")
    two = place("two")
    create = create_of_event(sender, %{"location" => [one, two]})
    assert {:ok, _} = delivered(create, sender)

    ActivityPub.Utils.repo().delete_all(
      Ecto.Query.from(o in Object, where: fragment("?->>'id' = ?", o.data, ^two["id"]))
    )


    assert [%{"id" => id, "name" => "one"}, second] = outgoing(create)["object"]["location"]
    assert id == one["id"]
    assert second == two["id"]
  end

  test "a nested object with its own proof goes out as it arrived, and its proof holds", %{
    sender: sender
  } do
    owner = "https://venue-#{System.unique_integer([:positive])}.example/users/owner"
    key = new_key(:ed25519)
    actor(ap_id: owner, data: %{"assertionMethod" => [multikey(owner, key)]})

    venue =
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => owner <> "/places/1",
        "type" => "Place",
        "attributedTo" => owner,
        "name" => "a signed venue"
      }
      |> sign(key, verification_method: owner <> "#ed25519-key")

    create = create_of_event(sender, %{"location" => venue})
    assert {:ok, _} = delivered(create, sender)

    assert %{"location" => %{"id" => id, "name" => "a signed venue"} = embedded} =
             outgoing(create)["object"]

    assert id == venue["id"]
    assert ActivityPub.Safety.IntegrityProofs.verify(embedded) == {:ok, owner}
  end

  test "a local object is left as it is" do
    n = System.unique_integer([:positive])
    venue = place()

    {:ok, _} =
      Object.do_insert(%{
        data: venue,
        local: false,
        public: true,
        is_object: true
      })

    {:ok, local} =
      Object.do_insert(%{
        data: %{
          "id" => "https://localhost/pub/objects/#{n}",
          "type" => "Event",
          "name" => "ours",
          "location" => venue["id"]
        },
        local: true,
        public: true,
        is_object: true
      })

    {:ok, out} =
      Transformer.prepare_outgoing(%{
        "type" => "Create",
        "id" => "https://localhost/pub/activities/#{n}",
        "actor" => "https://localhost/pub/actors/ours",
        "object" => local.data["id"]
      })

    assert out["object"]["location"] == venue["id"]
  end

  defp flush_fetches do
    receive do
      {:fetched, _} -> flush_fetches()
    after
      0 -> :ok
    end
  end
end
