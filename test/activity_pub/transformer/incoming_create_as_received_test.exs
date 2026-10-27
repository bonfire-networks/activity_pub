defmodule ActivityPub.Federator.Transformer.IncomingCreateAsReceivedTest do
  @moduledoc """
  A `Create` from another instance is stored as its author sent it, normalised but not rebuilt, as an `Update` or a `Delete` is.

  A rebuilt `Create` keeps only what the builder copies, so whatever else the author wrote (`audience`, extension fields) is lost, and its `context` is replaced by its object's. What the builder adds that an author may leave out is still added: the author we resolved as `actor`, and `published`.

  `@context` is not stored for any received row: nothing reads it from a stored row, and where it counts, for a signed document, the document is kept as received beside the row.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    n = System.unique_integer([:positive])
    author_id = "https://author-#{n}.example/users/author"
    actor(ap_id: author_id)

    %{author_id: author_id, n: n}
  end

  defp delivered(document, signer \\ nil),
    do:
      Transformer.handle_incoming(document,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: signer || document["actor"]
      )

  defp note(%{author_id: author_id}, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "#{author_id}/objects/#{System.unique_integer([:positive])}",
        "type" => "Note",
        "attributedTo" => author_id,
        "content" => "<p>hi</p>",
        "to" => [@public]
      },
      extra
    )
  end

  defp create_of(%{author_id: author_id}, object, extra \\ %{}) do
    Map.merge(
      %{
        "@context" => [
          "https://www.w3.org/ns/activitystreams",
          %{"extension" => "https://extension.example/ns#extension"}
        ],
        "id" => "#{author_id}/activities/create-#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => author_id,
        "to" => [@public],
        "object" => object
      },
      extra
    )
  end

  defp stored(ap_id) do
    assert {:ok, %Object{data: data}} = Object.get_uncached(ap_id: ap_id)
    data
  end

  test "keeps what the author wrote that the builder does not copy", context do
    group = "https://author-#{context.n}.example/groups/group"
    # known, as the adapter looks up who an activity is addressed to, `audience` included
    actor(ap_id: group)

    create =
      create_of(context, note(context), %{
        "audience" => group,
        "extension" => "an extension field"
      })

    assert {:ok, _} = delivered(create)

    assert %{"id" => id, "audience" => ^group, "extension" => "an extension field"} =
             stored(create["id"])

    assert id == create["id"], "stored under another id than its author's"
  end

  test "keeps the author it names as its actor", context do
    create = create_of(context, note(context))
    assert {:ok, _} = delivered(create)

    assert stored(create["id"])["actor"] == context.author_id
  end

  test "with no author it can resolve, is attributed to its verified signer, as before",
       context do
    create =
      create_of(context, Map.delete(note(context), "attributedTo"))
      |> Map.delete("actor")

    assert {:ok, _} = delivered(create, context.author_id)

    assert stored(create["id"])["actor"] == context.author_id
  end

  describe "published" do
    test "is kept when given", context do
      create = create_of(context, note(context), %{"published" => "2026-10-24T09:00:00Z"})
      assert {:ok, _} = delivered(create)

      assert stored(create["id"])["published"] == "2026-10-24T09:00:00Z"
    end

    test "is set when not given", context do
      create = create_of(context, note(context))
      assert {:ok, _} = delivered(create)

      assert is_binary(stored(create["id"])["published"])
    end
  end

  describe "context" do
    test "a Create without one is stored without one, not with its object's", context do
      conversation = "tag:author-#{context.n}.example,2026:conversation"
      create = create_of(context, note(context, %{"context" => conversation}))
      assert {:ok, _} = delivered(create)

      refute Map.has_key?(stored(create["id"]), "context"),
             "the Create was given its object's context"

      assert stored(create["object"]["id"])["context"] == conversation
    end

    test "a Create with its own keeps it, and its object keeps its own", context do
      activity_context = "https://author-#{context.n}.example/contexts/activity"
      object_context = "https://author-#{context.n}.example/contexts/object"

      create =
        create_of(context, note(context, %{"context" => object_context}), %{
          "context" => activity_context
        })

      assert {:ok, _} = delivered(create)

      assert stored(create["id"])["context"] == activity_context

      assert stored(create["object"]["id"])["context"] == object_context,
             "the object's context was overwritten with the activity's"
    end
  end

  test "delivered twice is stored once", context do
    create = create_of(context, note(context))
    assert {:ok, _} = delivered(create)
    delivered(create)

    assert 1 ==
             repo().aggregate(
               from(o in Object, where: fragment("(?)->>'id' = ?", o.data, ^create["id"])),
               :count
             )
  end

  describe "@context is not stored" do
    test "for a received Create", context do
      create = create_of(context, note(context))
      assert {:ok, _} = delivered(create)

      refute Map.has_key?(stored(create["id"]), "@context")
    end

    test "for a received Like", context do
      create = create_of(context, note(context))
      assert {:ok, _} = delivered(create)

      like = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{context.author_id}/likes/#{context.n}",
        "type" => "Like",
        "actor" => context.author_id,
        "object" => create["object"]["id"]
      }

      assert {:ok, _} = delivered(like)

      refute Map.has_key?(stored(like["id"]), "@context")
    end

    test "for an object stored on its own, as a fetched one is", context do
      object = Map.put(note(context), "@context", "https://www.w3.org/ns/activitystreams")
      assert {:ok, _} = Object.insert(object, false)

      refute Map.has_key?(stored(object["id"]), "@context")
    end
  end
end
