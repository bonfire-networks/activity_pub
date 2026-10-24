defmodule ActivityPub.Federator.Transformer.EmbeddedObjectOwnershipTest do
  @moduledoc """
  FEP-fe34: an object embedded in an activity is trusted through that activity only if it has the same owner (and origin) AND the activity itself was authenticated as that owner. Otherwise the object has to be authenticated on its own, by a proof of its own, or by being fetched from where it lives.

  A `Create` or `Update` may legitimately carry an object of someone else (a container, a relay, an editor), so a difference is not refused: it just does not come for free.
  """
  use ActivityPub.DataCase, async: false
  use Repatch.ExUnit

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Object

  setup do
    test_pid = self()

    Repatch.patch(Adapter.adapter(), :handle_activity, [mode: :shared], fn activity ->
      send(test_pid, {:handed_over, activity})
      Repatch.real(Adapter.adapter().handle_activity(activity))
    end)

    n = System.unique_integer([:positive])
    sender = person("https://sender-#{n}.example/users/sender")
    author = person("https://author-#{n}.example/users/author")

    %{n: n, sender: sender, author: author}
  end

  defp person(id) do
    key = new_key(:ed25519)
    actor(ap_id: id, data: %{"assertionMethod" => [multikey(id, key)]})
    %{id: id, key: key}
  end

  # a Create by `sender` of a note attributed to `owner`, the note's id on the owner's origin
  defp create_of(sender, owner, content \\ "<p>as the sender embeds it</p>") do
    n = System.unique_integer([:positive])

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{sender.id}/activities/#{n}",
      "type" => "Create",
      "actor" => sender.id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "object" => %{
        "id" => "#{owner.id}/notes/#{n}",
        "type" => "Note",
        "attributedTo" => owner.id,
        "content" => content,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }
    }
  end

  defp origin_serves_nothing,
    do: Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

  # the note as the adapter was handed it, inside the Create
  defp handed_over_note(create_id) do
    receive do
      {:handed_over, %Object{data: %{"id" => ^create_id}, object: %Object{} = note}} -> note
    after
      0 -> nil
    end
  end

  defp delivered(create, authenticated, signed_by \\ nil),
    do:
      Transformer.handle_incoming(create,
        from_inbox: true,
        authenticated: authenticated,
        signed_by: signed_by
      )

  describe "a note with the same owner as the Create" do
    test "inherits the authentication of a Create made by that owner", %{sender: sender} do
      create = create_of(sender, sender)

      assert {:ok, _} = delivered(create, :http_signature, sender.id)

      # the signature covers the whole document, the note as much as the Create
      assert %Object{authenticated: :http_signature, signed_by: by} =
               handed_over_note(create["id"])

      assert by == sender.id
    end

    test "is unverified when the Create was authenticated by no one", %{sender: sender} do
      create = create_of(sender, sender)

      assert {:ok, _} = delivered(create, nil)
      assert %Object{authenticated: :unverified, signed_by: nil} = handed_over_note(create["id"])
    end

    test "is unverified when the Create was authenticated as somebody else", %{sender: sender} do
      create = create_of(sender, sender)

      assert {:ok, _} =
               delivered(create, :http_signature, "https://some-group.example/pub/group/1")

      assert %Object{authenticated: :unverified, signed_by: nil} = handed_over_note(create["id"])
    end
  end

  describe "a note that names no owner" do
    # nothing says the sender owns it, so it does not get the sender's signature as its own: it rides in a document its sender vouched for, which is `embedded`
    defp create_of_ownerless(sender) do
      create = create_of(sender, sender)
      update_in(create, ["object"], &Map.delete(&1, "attributedTo"))
    end

    test "is embedded when the Create was authenticated as its sender", %{sender: sender} do
      create = create_of_ownerless(sender)

      assert {:ok, _} = delivered(create, :http_signature, sender.id)

      assert %Object{authenticated: :embedded, signed_by: by} = handed_over_note(create["id"])
      assert by == sender.id
    end

    test "is unverified when the Create was authenticated by no one", %{sender: sender} do
      create = create_of_ownerless(sender)

      assert {:ok, _} = delivered(create, nil)
      assert %Object{authenticated: :unverified, signed_by: nil} = handed_over_note(create["id"])
    end

    test "is unverified when the Create was authenticated as somebody else", %{sender: sender} do
      create = create_of_ownerless(sender)

      assert {:ok, _} =
               delivered(create, :http_signature, "https://some-group.example/pub/group/1")

      assert %Object{authenticated: :unverified, signed_by: nil} = handed_over_note(create["id"])
    end
  end

  describe "a note owned by someone else than the sender of the Create" do
    test "with a valid proof of its own by its owner is accepted as the owner's", %{
      sender: sender,
      author: author
    } do
      origin_serves_nothing()
      create = create_of(sender, author)
      signed_note = sign(create["object"], author.key)
      create = Map.put(create, "object", signed_note)

      assert {:ok, _} = delivered(create, :http_signature, sender.id)

      assert %Object{authenticated: :integrity_proof, signed_by: by} =
               handed_over_note(create["id"])

      assert by == author.id
    end

    test "with a proof that is the SENDER's is evidence against it, and it is not stored", %{
      sender: sender,
      author: author
    } do
      origin_serves_nothing()
      create = create_of(sender, author, "<p>forged under the author's name</p>")
      note = create["object"]

      forged = sign(note, sender.key, verification_method: sender.id <> "#ed25519-key")
      create = Map.put(create, "object", forged)

      assert {:error, _} = delivered(create, :http_signature, sender.id)

      assert {:error, :not_found} = Object.get_cached(ap_id: note["id"]),
             "a proof by someone other than the owner says the note is not the owner's"
    end

    test "with a proof that fails is evidence against it, and it is not stored", %{
      sender: sender,
      author: author
    } do
      origin_serves_nothing()
      create = create_of(sender, author, "<p>as the author signed it</p>")
      note = create["object"]

      altered =
        sign(note, author.key) |> Map.put("content", "<p>altered after it was signed</p>")

      create = Map.put(create, "object", altered)

      assert {:error, _} = delivered(create, :http_signature, sender.id)
      assert {:error, :not_found} = Object.get_cached(ap_id: note["id"])
    end

    test "with no proof is stored as it came, marked unverified, with nothing fetched", %{
      sender: sender,
      author: author,
      n: n
    } do
      test_pid = self()

      Tesla.Mock.mock(fn %{method: :get, url: url} ->
        send(test_pid, {:fetched, url})
        %Tesla.Env{status: 404, body: ""}
      end)

      create = create_of(sender, author, "<p>as the sender embeds it #{n}</p>")
      note = create["object"]
      note_id = note["id"]

      assert {:ok, _} = delivered(create, :http_signature, sender.id)

      assert {:ok, %Object{data: %{"content" => content}}} = Object.get_cached(ap_id: note["id"])
      assert content =~ "as the sender embeds it"

      assert %Object{authenticated: :unverified} = handed_over_note(create["id"]),
             "unverified, which is not the same as no claim (nil)"

      refute_received {:fetched, ^note_id}, "the owner's server is not asked"
    end

    test "with a proof we cannot check counts as having none", %{sender: sender, author: author} do
      origin_serves_nothing()
      create = create_of(sender, author)

      unknown_suite =
        sign(create["object"], author.key, proof: %{"cryptosuite" => "ecdsa-rdfc-2019"})

      create = Map.put(create, "object", unknown_suite)

      assert {:ok, _} = delivered(create, :http_signature, sender.id)
      assert %Object{authenticated: :unverified} = handed_over_note(create["id"])
    end

    test "is left alone when we fetched the Create ourselves", %{sender: sender, author: author} do
      origin_serves_nothing()
      create = create_of(sender, author)

      # nobody delivered this to us, so it is not for a delivery's rules to judge
      assert {:ok, _} =
               Transformer.handle_incoming(create, already_fetched: create["id"])
    end
  end

  describe "an Update" do
    # FEP-fe34, ownership transfer: the new owner has to be on the same origin as the old one, and only the current owner may hand an object over. The Update's `actor` is the current owner in all of these; what differs is who the delivery was authenticated as and where the new owner lives.
    defp object_of_sender_then_update_handing_it_to(sender, new_owner_id) do
      create = create_of(sender, sender)
      assert {:ok, _} = delivered(create, :http_signature, sender.id)

      update = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{sender.id}/activities/update-#{System.unique_integer([:positive])}",
        "type" => "Update",
        "actor" => sender.id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" =>
          create["object"]
          |> Map.put("attributedTo", new_owner_id)
          |> Map.put("content", "<p>now someone else's</p>")
      }

      {create["object"]["id"], update}
    end

    defp owner_and_content_of(object_id) do
      {:ok, %Object{data: %{"attributedTo" => owner, "content" => content}}} =
        Object.get_cached(ap_id: object_id)

      {owner, content}
    end

    test "may hand an object to an owner on the same origin, when authenticated as the current owner",
         %{sender: sender, n: n} do
      colleague = person("https://sender-#{n}.example/users/colleague")
      {object_id, update} = object_of_sender_then_update_handing_it_to(sender, colleague.id)

      assert {:ok, _} = delivered(update, :http_signature, sender.id)

      assert {owner, content} = owner_and_content_of(object_id)
      assert owner == colleague.id
      assert content =~ "now someone else's"
    end

    test "may not, when the delivery was authenticated as no one", %{sender: sender, n: n} do
      colleague = person("https://sender-#{n}.example/users/colleague")
      {object_id, update} = object_of_sender_then_update_handing_it_to(sender, colleague.id)

      assert {:error, _} = delivered(update, nil)

      assert {owner, content} = owner_and_content_of(object_id)
      assert owner == sender.id
      refute content =~ "someone else's"
    end

    test "may not, when the delivery was authenticated as someone else, an admin say", %{
      sender: sender,
      n: n
    } do
      colleague = person("https://sender-#{n}.example/users/colleague")
      {object_id, update} = object_of_sender_then_update_handing_it_to(sender, colleague.id)

      assert {:error, _} =
               delivered(update, :http_signature, "https://sender-#{n}.example/users/admin")

      assert {owner, _} = owner_and_content_of(object_id)
      assert owner == sender.id
    end

    test "may not hand an object to an owner on another origin, though authenticated as the current owner",
         %{sender: sender, author: author} do
      {object_id, update} = object_of_sender_then_update_handing_it_to(sender, author.id)

      assert {:error, _} = delivered(update, :http_signature, sender.id)

      assert {owner, content} = owner_and_content_of(object_id)
      assert owner == sender.id
      refute content =~ "someone else's"
    end

    test "that keeps the owner still updates it", %{sender: sender} do
      create = create_of(sender, sender)
      assert {:ok, _} = delivered(create, :http_signature, sender.id)

      update = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{sender.id}/activities/update-#{System.unique_integer([:positive])}",
        "type" => "Update",
        "actor" => sender.id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => Map.put(create["object"], "content", "<p>an honest edit</p>")
      }

      assert {:ok, _} = delivered(update, :http_signature, sender.id)

      assert {:ok, %Object{data: %{"content" => content}}} =
               Object.get_cached(ap_id: create["object"]["id"])

      assert content =~ "honest edit"
    end
  end
end
