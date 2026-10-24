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
