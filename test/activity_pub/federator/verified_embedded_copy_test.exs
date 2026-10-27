defmodule ActivityPub.Federator.VerifiedEmbeddedCopyTest do
  @moduledoc """
  An activity about a post we do not hold (a like, a boost) may carry a copy of the post. One whose own proof or LD signature, by its author, holds is as good as the post fetched from its origin: it is stored from the copy, marked as vouched for by that signature and kept as it arrived, and nothing is fetched. Any other copy is not trusted, and the post is fetched from its origin, as before.

  The origin serves nothing for the post here, so a post stored from the copy cannot have come from a fetch.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers
  import Tesla.Mock

  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer

  @public "https://www.w3.org/ns/activitystreams#Public"
  @context [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/data-integrity/v2"
  ]

  setup do
    n = System.unique_integer([:positive])

    key = new_key(:ed25519)
    author = "https://author-#{n}.local/users/alice"
    actor(ap_id: author, data: %{"assertionMethod" => [multikey(author, key)]})

    other_key = new_key(:ed25519)
    stranger = "https://stranger-#{n}.local/users/mallory"
    actor(ap_id: stranger, data: %{"assertionMethod" => [multikey(stranger, other_key)]})

    booster = "https://booster-#{n}.local/users/bob"
    actor(ap_id: booster)

    # the post's origin serves nothing
    mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    note =
      author
      |> create_note()
      |> Map.fetch!("object")
      |> Map.put("@context", @context)
      |> Map.put("published", "2015-03-01T12:00:00Z")

    %{
      author: author,
      key: key,
      stranger: stranger,
      other_key: other_key,
      booster: booster,
      note: note
    }
  end

  defp signed(note, key, signer),
    do: sign(note, key, verification_method: signer <> "#ed25519-key")

  defp activity(type, actor, object) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{actor}/activities/#{System.unique_integer([:positive])}",
      "type" => type,
      "actor" => actor,
      "to" => [@public],
      "object" => object
    }
  end

  # delivered over its actor's HTTP signature, as the receiver hands it on
  defp delivered(activity),
    do:
      Transformer.handle_incoming(activity,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: activity["actor"]
      )

  for type <- ["Like", "Announce"] do
    describe "a #{type} carrying the post" do
      test "signed by its author: the post is stored from the copy, as vouched for by the proof",
           %{note: note, key: key, author: author, booster: booster} do
        copy = signed(note, key, author)

        assert {:ok, _} = delivered(activity(unquote(type), booster, copy))

        assert {:ok, %Object{authenticated: :integrity_proof, data_received: ^copy}} =
                 Object.get_uncached(ap_id: note["id"])
      end

      test "with no proof: not trusted, so fetched, and not stored when its origin serves nothing",
           %{note: note, booster: booster} do
        delivered(activity(unquote(type), booster, note))

        assert {:error, :not_found} = Object.get_uncached(ap_id: note["id"])
      end

      test "signed by somebody else: not trusted, as with no proof",
           %{note: note, other_key: other_key, stranger: stranger, booster: booster} do
        delivered(activity(unquote(type), booster, signed(note, other_key, stranger)))

        assert {:error, :not_found} = Object.get_uncached(ap_id: note["id"])
      end

      test "changed after its author signed it: not trusted, as with no proof",
           %{note: note, key: key, author: author, booster: booster} do
        copy = note |> signed(key, author) |> Map.put("content", "<p>changed</p>")

        delivered(activity(unquote(type), booster, copy))

        assert {:error, :not_found} = Object.get_uncached(ap_id: note["id"])
      end
    end
  end
end
