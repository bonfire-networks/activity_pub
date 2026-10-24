defmodule ActivityPub.Federator.RefetchTest do
  @moduledoc """
  Fetching an object we already hold from its origin stores what was fetched, by the same rule as any other copy that arrives again (`ActivityPub.Safety.replaces?/3`): the origin's copy is vouched for (`fetched`), so it replaces the stored one unless it is provably older, and an identical one only changes the mark.

  Every refetch goes through here: a group's relay checked against the origin, an unsigned delivery confirmed by fetching, a background refresh, a quote authorization checked again.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Object
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Transformer

  @public "https://www.w3.org/ns/activitystreams#Public"
  @t1 "2026-10-01T10:00:00Z"
  @t2 "2026-10-02T10:00:00Z"

  setup do
    n = System.unique_integer([:positive])
    author_id = "https://author-#{n}.example/users/author"
    actor(ap_id: author_id)

    note = %{
      "id" => "#{author_id}/objects/#{n}",
      "type" => "Note",
      "attributedTo" => author_id,
      "content" => "<p>as we first got it</p>",
      "to" => [@public],
      "published" => @t1
    }

    # held, as a delivery nobody vouched for left it
    assert {:ok, _} =
             Transformer.handle_incoming(
               %{
                 "@context" => "https://www.w3.org/ns/activitystreams",
                 "id" => "#{author_id}/activities/create-#{n}",
                 "type" => "Create",
                 "actor" => author_id,
                 "to" => [@public],
                 "object" => note
               },
               from_inbox: true
             )

    assert row(note["id"]).authenticated == :unverified

    %{note: note}
  end

  defp row(ap_id) do
    {:ok, %Object{id: id}} = Object.get_cached(ap_id: ap_id)
    ActivityPub.Utils.repo().get!(Object, id)
  end

  # the origin serves this copy of the object
  defp origin_serves(document) do
    Tesla.Mock.mock(fn %{method: :get, url: url} ->
      if url == document["id"],
        do:
          Tesla.Mock.json(Map.put(document, "@context", "https://www.w3.org/ns/activitystreams")),
        else: %Tesla.Env{status: 404, body: ""}
    end)
  end

  test "stores the origin's newer copy, as fetched", %{note: note} do
    origin_serves(
      note
      |> Map.put("content", "<p>as the origin has it</p>")
      |> Map.put("updated", @t2)
    )

    assert {:ok, _} = Fetcher.fetch_fresh_object_from_id(note["id"])

    assert row(note["id"]).data["content"] == "<p>as the origin has it</p>"
    assert row(note["id"]).authenticated == :fetched
  end

  test "stores the origin's copy when neither has a later date, since it is vouched for", %{
    note: note
  } do
    origin_serves(Map.put(note, "content", "<p>as the origin has it</p>"))

    assert {:ok, _} = Fetcher.fetch_fresh_object_from_id(note["id"])

    assert row(note["id"]).data["content"] == "<p>as the origin has it</p>"
  end

  test "keeps the stored copy when the origin's is provably older", %{note: note} do
    newer = note |> Map.put("content", "<p>a later edit we got</p>") |> Map.put("updated", @t2)

    assert {:ok, _} =
             Object.replace(row(note["id"]), newer, :http_signature)

    origin_serves(note |> Map.put("content", "<p>an older copy</p>") |> Map.put("updated", @t1))

    assert {:ok, _} = Fetcher.fetch_fresh_object_from_id(note["id"])

    assert row(note["id"]).data["content"] == "<p>a later edit we got</p>"
    assert row(note["id"]).authenticated == :http_signature
  end

  test "an identical copy only changes the mark", %{note: note} do
    before = row(note["id"]).data
    origin_serves(note)

    assert {:ok, _} = Fetcher.fetch_fresh_object_from_id(note["id"])

    assert row(note["id"]).data["content"] == before["content"]
    assert row(note["id"]).authenticated == :fetched
  end

  test "a background refetch (a fresh fetch job) stores the origin's copy too", %{note: note} do
    origin_serves(
      note
      |> Map.put("content", "<p>as the origin has it</p>")
      |> Map.put("updated", @t2)
    )

    assert {:ok, _job} = Fetcher.enqueue_fetch(note["id"], %{"fresh" => true})
    ActivityPub.Tests.ObanHelpers.perform_all()

    assert row(note["id"]).data["content"] == "<p>as the origin has it</p>"
    assert row(note["id"]).authenticated == :fetched
  end

  # what a quote authorization's check meets when the author revoked it (`Bonfire.Social.Quotes.verify_quote_authorization/3` refetches it, `return_tombstones: true`, then asks `Object.is_deleted?/1`)
  test "an object deleted at its origin is stored as deleted, so a check of it sees it is gone",
       %{
         note: note
       } do
    origin_serves(%{
      "id" => note["id"],
      "type" => "Tombstone",
      "formerType" => "Note",
      "deleted" => @t2
    })

    assert {:ok, refetched} =
             Fetcher.fetch_fresh_object_from_id(note["id"], return_tombstones: true)

    assert Object.is_deleted?(refetched),
           "a revoked authorization we held would otherwise still look valid"
  end

  test "returns the stored copy as it now is", %{note: note} do
    origin_serves(
      note
      |> Map.put("content", "<p>as the origin has it</p>")
      |> Map.put("updated", @t2)
    )

    assert {:ok, %Object{data: %{"content" => "<p>as the origin has it</p>"}}} =
             Fetcher.fetch_fresh_object_from_id(note["id"])
  end
end
