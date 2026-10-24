defmodule ActivityPub.Federator.NestedObjectsTest do
  @moduledoc """
  An object can carry other objects in its fields (an event's `location`, a recipe's `instrument`, a service's `generator`). `NestedObjects.ingest/2` stores each of them as an object of its own and leaves its AP id where the embedded map was, so the document stays plain ActivityPub and a reader loads the object by id. Which fields hold objects is read from the document's `@context` (see `NestedObjects.Terms`). The library knows nothing of what a caller points with.
  """
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Actor
  alias ActivityPub.Federator.NestedObjects
  alias ActivityPub.Object

  setup do
    n = System.unique_integer([:positive])
    %{n: n, host: "nested-#{n}.example"}
  end

  defp place(host, name, label \\ "p") do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://#{host}/places/#{label}-#{System.unique_integer([:positive])}",
      "type" => "Place",
      "name" => name
    }
  end

  defp event(host, fields) do
    Map.merge(
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://#{host}/events/#{System.unique_integer([:positive])}",
        "type" => "Event",
        "name" => "an event",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      },
      fields
    )
  end

  # the nested objects' servers answer with `served` documents (by id), and tell the test which URLs were asked for
  defp serve(served) do
    test_pid = self()

    Tesla.Mock.mock(fn %{method: :get, url: url} ->
      send(test_pid, {:fetched, url})

      case Enum.find(served, &(&1["id"] == url)) do
        nil -> %Tesla.Env{status: 404, body: ""}
        document -> Tesla.Mock.json(document)
      end
    end)
  end

  defp stored_name(id) do
    assert {:ok, %Object{data: %{"name" => name}}} = Object.get_cached(ap_id: id)
    name
  end

  test "a nested object is stored from its origin's copy and replaced by its id", %{host: host} do
    served = place(host, "as the origin serves it")
    embedded = Map.put(served, "name", "as the event embeds it")
    serve([served])

    result = NestedObjects.ingest(event(host, %{"location" => embedded}))

    id = served["id"]
    assert result["location"] == id

    assert stored_name(id) == "as the origin serves it",
           "the origin's copy wins over the embedded one"

    assert_received {:fetched, ^id}
  end

  test "an embedded copy is stored when the origin cannot be asked", %{host: host} do
    embedded = place(host, "as the event embeds it")
    serve([])

    result = NestedObjects.ingest(event(host, %{"location" => embedded}))

    assert result["location"] == embedded["id"]
    assert stored_name(embedded["id"]) == "as the event embeds it"
  end

  test "each object of a list is stored and replaced", %{host: host} do
    one = place(host, "one", "a")
    two = place(host, "two", "b")
    serve([one, two])

    result = NestedObjects.ingest(event(host, %{"location" => [one, two]}))

    assert result["location"] == [one["id"], two["id"]]
    assert stored_name(one["id"]) == "one"
    assert stored_name(two["id"]) == "two"
  end

  test "an actor is stored as an actor", %{host: host} do
    app = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://#{host}/actors/app",
      "type" => "Application",
      "preferredUsername" => "app",
      "inbox" => "https://#{host}/actors/app/inbox"
    }

    serve([app])

    result = NestedObjects.ingest(event(host, %{"generator" => app}))

    assert result["generator"] == app["id"]
    assert {:ok, %Actor{}} = Actor.get_cached(ap_id: app["id"])
  end

  test "the fields that name somebody or something else are left alone", %{host: host} do
    author = %{"id" => "https://#{host}/users/alice", "type" => "Person", "name" => "Alice"}
    reply_to = %{"id" => "https://#{host}/notes/1", "type" => "Note"}
    serve([author, reply_to])

    document = event(host, %{"attributedTo" => author, "inReplyTo" => reply_to})

    assert NestedObjects.ingest(document) == document
    refute_received {:fetched, _}
  end

  test "a field the context does not define as an IRI is left alone, whatever it holds", %{
    host: host
  } do
    embedded = place(host, "in a field no context knows")
    serve([embedded])

    document = event(host, %{"somethingElse" => embedded})

    assert NestedObjects.ingest(document) == document
    refute_received {:fetched, _}
  end

  test "a field the document's own context defines as an IRI is ingested", %{host: host} do
    embedded = place(host, "in a field the document defines")
    serve([embedded])

    document =
      event(host, %{
        "@context" => [
          "https://www.w3.org/ns/activitystreams",
          %{"venue" => %{"@id" => "ex:venue", "@type" => "@id"}}
        ],
        "venue" => embedded
      })

    assert NestedObjects.ingest(document)["venue"] == embedded["id"]
  end

  test "include_fields ingests a field no context defines, exclude_fields leaves one alone", %{
    host: host
  } do
    one = place(host, "in a field of our choosing")
    two = place(host, "in a field we leave out")
    serve([one, two])

    document = event(host, %{"somethingElse" => one, "location" => two})

    result =
      NestedObjects.ingest(document,
        include_fields: ["somethingElse"],
        exclude_fields: ["location"]
      )

    assert result["somethingElse"] == one["id"]
    assert result["location"] == two
  end

  test "a value that is not an object we know is left alone", %{host: host} do
    serve([])

    document =
      event(host, %{
        "tag" => [
          %{"type" => "Hashtag", "name" => "#salad", "href" => "https://#{host}/tags/salad"}
        ],
        "instrument" => %{"id" => "https://#{host}/x/1", "type" => "Frobnicate"},
        "plain" => "text"
      })

    assert NestedObjects.ingest(document) == document
    refute_received {:fetched, _}
  end

  test "a nested object with no id has nothing to fetch or store and stays embedded", %{
    host: host
  } do
    serve([])
    anonymous = %{"type" => "Place", "name" => "somewhere", "latitude" => 1.5, "longitude" => 2.5}

    document = event(host, %{"location" => anonymous})

    assert NestedObjects.ingest(document) == document
    refute_received {:fetched, _}
  end

  test "with fetching off the embedded copy is stored, and nobody is asked", %{host: host} do
    served = place(host, "as the origin serves it")
    embedded = Map.put(served, "name", "as the event embeds it")
    serve([served])

    result = NestedObjects.ingest(event(host, %{"location" => embedded}), fetch_remote?: false)

    assert result["location"] == embedded["id"]
    assert stored_name(embedded["id"]) == "as the event embeds it"
    refute_received {:fetched, _}
  end
end
