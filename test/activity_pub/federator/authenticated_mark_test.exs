defmodule ActivityPub.Federator.AuthenticatedMarkTest do
  @moduledoc """
  How a document was authenticated travels with it to the adapter, as `authenticated` (`nil` when it was not, else how: `:http_signature | :integrity_proof | :ld_signature | :refetch | :embedded`, or `:unverified`) and `signed_by` (the actor who vouched) on the `%Object{}`. Like `relayed_by`, `signed_by` describes the DELIVERY, so it is virtual: never stored, only carried to the adapter at the moment it handles the activity. `authenticated` is also kept on the row, see `ObjectAuthenticatedTest`.

  It is set for the document being handled, and each document has its own: a group's `Announce` signed by the group says nothing about the author's `Create` inside it.
  """
  use ActivityPub.DataCase, async: false
  use Repatch.ExUnit

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Federator.Worker.ReceiverHelpers
  alias ActivityPub.Object

  setup do
    test_pid = self()

    # nothing here is served: what the adapter does with the made-up activities of some tests may ask
    Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    # see what the adapter is handed, and let it go on as it would
    Repatch.patch(Adapter.adapter(), :handle_activity, [mode: :shared], fn activity ->
      send(test_pid, {:handed_over, activity})
      Repatch.real(Adapter.adapter().handle_activity(activity))
    end)

    :ok
  end

  # everything handed over so far, by the id of the document
  defp handed_over do
    Stream.repeatedly(fn ->
      receive do
        {:handed_over, %Object{data: %{"id" => id}} = object} -> {id, object}
      after
        0 -> :none
      end
    end)
    |> Enum.take_while(&(&1 != :none))
    |> Map.new()
  end

  defp remote_activity do
    %Object{
      local: false,
      data: %{
        "id" => "https://mark.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Like",
        "actor" => "https://mark.example/users/alice",
        "object" => "https://mark.example/objects/1"
      }
    }
  end

  describe "the hand-over to the adapter" do
    test "carries what the caller says about how the activity was authenticated" do
      activity = remote_activity()

      Adapter.maybe_handle_activity(activity,
        authenticated: :integrity_proof,
        signed_by: "https://mark.example/users/alice"
      )

      assert_received {:handed_over,
                       %Object{
                         authenticated: :integrity_proof,
                         signed_by: "https://mark.example/users/alice"
                       }}
    end

    test "is nil when nobody says" do
      Adapter.maybe_handle_activity(remote_activity(), [])

      assert_received {:handed_over, %Object{authenticated: nil}}
    end

    test "who vouched is not a stored property: a new struct has none, and it is not a column" do
      assert %Object{}.authenticated == nil
      assert %Object{}.signed_by == nil
      refute :signed_by in Object.__schema__(:fields)
    end

    test "a document checked and found without a usable proof is :unverified, with nobody who vouched" do
      Adapter.maybe_handle_activity(remote_activity(), authenticated: :unverified)

      assert_received {:handed_over, %Object{authenticated: :unverified, signed_by: nil}}
    end

    test "a delivery nobody vouched for is :unverified" do
      Adapter.maybe_handle_activity(remote_activity(), from_inbox: true)

      assert_received {:handed_over, %Object{authenticated: :unverified, signed_by: nil}}
    end
  end

  describe "an activity delivered with a verified HTTP signature" do
    test "is marked as signed by the actor the signature belongs to" do
      signer = actor()
      signer_id = ActivityPub.Utils.ap_id(signer)

      document = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{signer_id}/activities/like-#{System.unique_integer([:positive])}",
        "type" => "Like",
        "actor" => signer_id,
        "object" => insert(:note).data["id"]
      }

      job = %Oban.Job{
        args: %{
          "op" => "incoming_ap_doc",
          "params" => document,
          "repo" => ActivityPub.Utils.repo(),
          "signed_by" => signer_id
        }
      }

      ReceiverHelpers.perform(job, :mentions)

      assert %Object{authenticated: :http_signature, signed_by: ^signer_id} =
               handed_over()[document["id"]]
    end
  end

  describe "a document with an object integrity proof" do
    test "is marked as made by the controller of the key, via the proof" do
      author_id = "https://mark-#{System.unique_integer([:positive])}.example/users/alice"
      key = new_key(:ed25519)
      actor(ap_id: author_id, data: %{"assertionMethod" => [multikey(author_id, key)]})

      create = author_id |> create_note() |> sign(key)

      ReceiverHelpers.maybe_process_unsigned(%{}, create)

      assert %Object{authenticated: :integrity_proof, signed_by: ^author_id} =
               handed_over()[create["id"]]
    end
  end

  describe "a relayed activity" do
    setup do
      mock_unreachable_origin()

      author_id = "https://mark-#{System.unique_integer([:positive])}.example/users/alice"
      key = new_key(:ed25519)
      actor(ap_id: author_id, data: %{"assertionMethod" => [multikey(author_id, key)]})

      %{author_id: author_id, key: key, group: insert(:actor)}
    end

    defp mock_unreachable_origin,
      do: Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    defp announce_of(group, activity) do
      %{
        "type" => "Announce",
        "id" => "#{group.data["id"]}/activities/announce/#{System.unique_integer([:positive])}",
        "actor" => group.data["id"],
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => activity
      }
    end

    test "the inner activity is marked with its own proof, not with the group's authentication",
         %{author_id: author_id, key: key, group: group} do
      create = author_id |> create_note() |> sign(key)
      group_id = group.data["id"]
      announce = announce_of(group, create)

      # the group's Announce itself came in with a verified HTTP signature
      assert {:ok, _} =
               Transformer.handle_incoming(announce,
                 authenticated: :http_signature,
                 signed_by: group_id
               )

      handed = handed_over()

      assert %Object{authenticated: :integrity_proof, signed_by: ^author_id} =
               handed[create["id"]],
             "the author's server made the Create, whoever passed it on"

      assert %Object{authenticated: :http_signature, signed_by: ^group_id} =
               handed[announce["id"]],
             "and the group's own Announce keeps the group's"
    end

    test "an inner activity nothing vouches for is not marked, though the group's delivery was",
         %{author_id: author_id, group: group} do
      unsigned = create_note(author_id)
      group_id = group.data["id"]

      assert {:ok, _} =
               Transformer.handle_incoming(announce_of(group, unsigned),
                 authenticated: :http_signature,
                 signed_by: group_id
               )

      assert %Object{authenticated: nil} = handed_over()[unsigned["id"]],
             "the group's signature covers the group's Announce, not what it carries"
    end
  end
end
