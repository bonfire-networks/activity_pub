defmodule ActivityPub.ObjectHeldAncestorsTest do
  @moduledoc """
  `ActivityPub.Object.held_ancestors/1`: the posts up an object's reply chain (`inReplyTo`, then its `inReplyTo`, and so on), nearest first, as far as we hold them. Nothing is fetched.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Object

  defp ids(objects), do: Enum.map(objects, & &1.data["id"])

  defp reply_to(parent, data \\ %{}),
    do: insert(:note, data: Map.put(data, "inReplyTo", parent.data["id"]))

  test "are the posts up the chain, nearest first" do
    root = insert(:note)
    parent = reply_to(root)
    reply = reply_to(parent)

    assert ids(Object.held_ancestors(reply)) == ids([parent, root])
  end

  test "are none for a post that replies to nothing" do
    assert Object.held_ancestors(insert(:note)) == []
  end

  test "stop at the first post we do not hold" do
    parent = insert(:note, data: %{"inReplyTo" => "https://elsewhere.local/notes/not-held"})
    reply = reply_to(parent)

    assert ids(Object.held_ancestors(reply)) == ids([parent])
  end

  test "take an inReplyTo given as an object" do
    root = insert(:note)
    reply = insert(:note, data: %{"inReplyTo" => %{"id" => root.data["id"], "type" => "Note"}})

    assert ids(Object.held_ancestors(reply)) == ids([root])
  end

  test "end when the chain loops back" do
    n = System.unique_integer([:positive])
    a_id = "https://loop-#{n}.local/notes/a"
    b_id = "https://loop-#{n}.local/notes/b"

    a = insert(:note, data: %{"id" => a_id, "inReplyTo" => b_id})
    b = insert(:note, data: %{"id" => b_id, "inReplyTo" => a_id})
    reply = reply_to(a)

    assert ids(Object.held_ancestors(reply)) == ids([a, b])
  end

  test "take a document as well as a stored object" do
    root = insert(:note)
    parent = reply_to(root)

    assert ids(Object.held_ancestors(%{"inReplyTo" => parent.data["id"]})) == ids([parent, root])
  end
end
