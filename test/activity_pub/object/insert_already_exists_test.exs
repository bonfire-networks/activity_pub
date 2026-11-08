defmodule ActivityPub.Object.InsertAlreadyExistsTest do
  @moduledoc """
  Storing an activity or object whose id is held already gives the tagged `{:error, :already_exists}`, so a caller can tell a redelivery from a failure (the receiver worker cancels the job instead of retrying it), and the functions in `ActivityPub` that build an activity hand that tag back unchanged rather than wrapping it into a text error.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Object

  defp remote_create(n) do
    actor = "https://remote-#{n}.local/users/alice"

    %{
      "id" => "#{actor}/activities/#{n}",
      "type" => "Create",
      "actor" => actor,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "object" => %{
        "id" => "#{actor}/notes/#{n}",
        "type" => "Note",
        "attributedTo" => actor,
        "content" => "<p>hi</p>",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }
    }
  end

  describe "Object.insert/4" do
    test "the same activity stored twice is tagged as already existing the second time" do
      n = System.unique_integer([:positive])
      create = remote_create(n)

      assert {:ok, %Object{}} = Object.insert(create, false, nil, from_inbox: true)

      assert {:error, :already_exists} = Object.insert(create, false, nil, from_inbox: true)
    end

    test "an activity without an object is tagged the same way" do
      n = System.unique_integer([:positive])
      actor = "https://remote-#{n}.local/users/alice"

      lock = %{
        "id" => "#{actor}/activities/#{n}",
        "type" => "Lock",
        "actor" => actor,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => "https://ours.local/objects/#{n}"
      }

      assert {:ok, %Object{}} = Object.insert(lock, false, nil, from_inbox: true)
      assert {:error, :already_exists} = Object.insert(lock, false, nil, from_inbox: true)
    end
  end

  describe "ActivityPub functions that insert an activity" do
    test "announce/2 with an activity id held already returns the tag, not a text error" do
      booster = insert(:actor)
      create = insert(:note_activity)
      note = Object.get_cached!(ap_id: create.data["object"])
      announce_id = "https://ours.local/announces/#{System.unique_integer([:positive])}"

      assert {:ok, %Object{}} =
               ActivityPub.announce(%{actor: booster, object: note, activity_id: announce_id})

      assert {:error, :already_exists} =
               ActivityPub.announce(%{actor: booster, object: note, activity_id: announce_id})
    end
  end
end
