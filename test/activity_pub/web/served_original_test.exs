defmodule ActivityPub.Web.ServedOriginalTest do
  @moduledoc """
  The route serves any public object we hold, someone else's included (`object_json` finds it by pointer id). One we hold with its original (`data_received`, kept when its proof or LD signature held) is served as the author sent it, so its proof still verifies for whoever fetches it. It is not rebuilt, and not put through the privacy step, which edits a copy (`bto`/`bcc`, URLs) and would break the author's proof. One without an original is served as before.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Federator.Worker.ReceiverHelpers
  alias ActivityPub.Object
  alias ActivityPub.Safety.IntegrityProofs
  alias ActivityPub.Web.ObjectView

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    n = System.unique_integer([:positive])
    key = new_key(:ed25519)
    author_id = "https://author-#{n}.example/users/author"
    actor(ap_id: author_id, data: %{"assertionMethod" => [multikey(author_id, key)]})
    %{key: key, author_id: author_id}
  end

  # over its author's verified HTTP signature, as the receiver worker gets it
  defp received(document, signer) do
    ReceiverHelpers.perform(
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

  defp served(ap_id) do
    {:ok, row} = Object.get_cached(ap_id: ap_id)
    ObjectView.render("object.json", %{object: row})
  end

  test "a Create we hold signed is served as its author sent it", %{
    key: key,
    author_id: author_id
  } do
    %{"object" => note} = create = author_id |> create_note() |> sign(key)
    create = Map.put(create, "object", sign(note, key)) |> Map.delete("proof") |> sign(key)
    assert {:ok, _} = received(create, author_id)

    served = served(create["id"])

    assert served == create
    assert IntegrityProofs.verify(served) == {:ok, author_id}
  end

  test "a post we hold signed is served as its author sent it", %{key: key, author_id: author_id} do
    %{"object" => note} = create = author_id |> create_note() |> sign(key)
    signed_note = sign(note, key)
    create = Map.put(create, "object", signed_note) |> Map.delete("proof") |> sign(key)
    assert {:ok, _} = received(create, author_id)

    served = served(note["id"])

    assert served == signed_note
    assert IntegrityProofs.verify(served) == {:ok, author_id}
  end

  test "an inbox lists a signed activity addressed to its owner as its author sent it", %{
    key: key,
    author_id: author_id
  } do
    %{username: username} = local_actor()
    {:ok, owner} = ActivityPub.Actor.get_cached(username: username)

    %{"object" => note} = create = create_note(author_id)
    note = Map.put(note, "to", [owner.ap_id])

    create =
      create |> Map.put("to", [owner.ap_id]) |> Map.put("object", sign(note, key)) |> sign(key)

    assert {:ok, _} = received(create, author_id)

    %{"orderedItems" => items} = ObjectView.render("inbox.json", %{actor: owner, page: 1})

    assert create in items

    assert IntegrityProofs.verify(Enum.find(items, &(&1["id"] == create["id"]))) ==
             {:ok, author_id}
  end

  describe "a post we hold signed, then deleted by its author" do
    # nothing is served by the author's origin (a followers-only post makes us look up its followers collection)
    setup do
      Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)
      :ok
    end

    # a signed post in a signed Create, with a content of its own so a leak of it can be told from anything else
    defp received_note(%{key: key, author_id: author_id}, to) do
      content = "<p>to be deleted #{System.unique_integer([:positive])}</p>"
      %{"object" => note} = create = create_note(author_id, content)
      note = note |> Map.put("to", to) |> sign(key)
      create = create |> Map.put("to", to) |> Map.put("object", note) |> sign(key)

      assert {:ok, _} = received(create, author_id)

      %{create: create, note: note, content: content}
    end

    # over the owner's HTTP signature, which needs no word from the origin (FEP-fe34, `owner_delete_test.exs`)
    defp deleted_by(author_id, object_id) do
      ActivityPub.Federator.Transformer.handle_incoming(
        %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => "#{author_id}/activities/delete-#{System.unique_integer([:positive])}",
          "type" => "Delete",
          "actor" => author_id,
          "to" => [@public],
          "object" => object_id
        },
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: author_id
      )
    end

    for followers_only? <- [false, true] do
      test "the post is served as a Tombstone, followers only: #{followers_only?}",
           %{
             author_id: author_id
           } = context do
        followers_only? = unquote(followers_only?)
        to = if followers_only?, do: ["#{author_id}/followers"], else: [@public]
        %{note: note, content: content} = received_note(context, to)

        {:ok, row} = Object.get_cached(ap_id: note["id"])
        assert %{"proof" => _} = row.data_received, "control: held with its original"
        assert row.public == not followers_only?
        assert served(note["id"]) == note, "control: served as its author sent it"

        assert {:ok, _} = deleted_by(author_id, note["id"])

        served = served(note["id"])
        assert served["type"] == "Tombstone"
        assert served["id"] == note["id"]
        refute Jason.encode!(served) =~ content

        {:ok, row} = Object.get_uncached(ap_id: note["id"])
        assert row.data["type"] == "Tombstone"
        assert is_nil(row.data_received)
      end

      test "the Create that carried it no longer serves it, followers only: #{followers_only?}",
           %{author_id: author_id} = context do
        to = if unquote(followers_only?), do: ["#{author_id}/followers"], else: [@public]
        %{create: create, note: note, content: content} = received_note(context, to)

        assert served(create["id"]) == create, "control: served as its author sent it"

        assert {:ok, _} = deleted_by(author_id, note["id"])

        refute Jason.encode!(served(create["id"])) =~ content
      end
    end
  end

  describe "a Create held signed is stored apart from its post, and put back together when served" do
    # the post is kept once, in its own row; the Create keeps its id, and is served with the post put back, so the author's proof still verifies. When the post's row changes (an edit, a delete), the Create can no longer be put back together and keeps nothing.
    setup do
      Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)
      :ok
    end

    defp signed_create(%{key: key, author_id: author_id}, sign_note?) do
      content = "<p>first version #{System.unique_integer([:positive])}</p>"
      %{"object" => note} = create = create_note(author_id, content)
      note = if sign_note?, do: sign(note, key), else: note
      create = create |> Map.put("object", note) |> sign(key)
      assert {:ok, _} = received(create, author_id)
      %{create: create, note: note, content: content}
    end

    defp update_of(%{key: key, author_id: author_id}, note, content, sign?) do
      note =
        note
        |> Map.delete("proof")
        |> Map.merge(%{
          "content" => content,
          "updated" => DateTime.to_iso8601(DateTime.utc_now())
        })

      note = if sign?, do: sign(note, key), else: note

      update = %{
        "@context" => [
          "https://www.w3.org/ns/activitystreams",
          "https://w3id.org/security/data-integrity/v2"
        ],
        "id" => "#{author_id}/activities/update-#{System.unique_integer([:positive])}",
        "type" => "Update",
        "actor" => author_id,
        "to" => [@public],
        "object" => note
      }

      if sign?, do: sign(update, key), else: update
    end

    defp held(ap_id) do
      {:ok, row} = Object.get_uncached(ap_id: ap_id)
      row
    end

    test "the post is kept in its own row, and the Create keeps its id", context do
      %{create: create, note: note} = signed_create(context, true)

      assert held(create["id"]).data_received["object"] == note["id"]
      assert held(note["id"]).data_received == note
    end

    test "a post with no proof of its own is kept too, as its Create's proof covers it",
         context do
      %{create: create, note: note} = signed_create(context, false)

      assert held(note["id"]).data_received == note
      assert served(create["id"]) == create
      assert IntegrityProofs.verify(served(create["id"])) == {:ok, context.author_id}
    end

    test "after a signed edit, the Create is no longer served with its first version", context do
      %{create: create, note: note, content: content} = signed_create(context, true)
      update = update_of(context, note, "<p>second version</p>", true)

      assert {:ok, _} = received(update, context.author_id)

      assert served(update["id"]) == update, "control: the edit is held signed"
      assert IntegrityProofs.verify(served(update["id"])) == {:ok, context.author_id}

      assert is_nil(held(create["id"]).data_received)
      refute Jason.encode!(served(create["id"])) =~ content
    end

    test "after an edit with no proof, neither the post nor its Create keeps an original",
         context do
      %{create: create, note: note} = signed_create(context, true)
      update = update_of(context, note, "<p>second version</p>", false)

      assert {:ok, _} =
               ActivityPub.Federator.Transformer.handle_incoming(update,
                 from_inbox: true,
                 authenticated: :http_signature,
                 signed_by: context.author_id
               )

      assert held(note["id"]).data["content"] == "<p>second version</p>", "control: edited"
      assert is_nil(held(note["id"]).data_received)
      assert is_nil(held(create["id"]).data_received)
    end

    test "after a second edit, only the latest edit is put back together", context do
      %{note: note} = signed_create(context, true)
      first = update_of(context, note, "<p>second version</p>", true)
      assert {:ok, _} = received(first, context.author_id)
      second = update_of(context, note, "<p>third version</p>", true)
      assert {:ok, _} = received(second, context.author_id)

      assert is_nil(held(first["id"]).data_received)
      assert served(second["id"]) == second
      assert IntegrityProofs.verify(served(second["id"])) == {:ok, context.author_id}
    end
  end

  test "one we hold unsigned is served rebuilt, with no proof", %{author_id: author_id} do
    create = create_note(author_id)
    assert {:ok, _} = received(create, author_id)

    served = served(create["id"])

    assert served["id"] == create["id"]
    refute Map.has_key?(served, "proof")
  end
end
