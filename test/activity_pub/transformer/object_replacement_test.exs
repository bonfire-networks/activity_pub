defmodule ActivityPub.Federator.Transformer.ObjectReplacementTest do
  @moduledoc """
  An object we already hold can arrive again, from another delivery, a relay or a fetch. Which copy stays:

    * a copy somebody vouched for replaces the stored one, whatever the stored one's value, unless it is provably older (by `updated`, else `published`)
    * a copy nobody vouched for never replaces one somebody did, and does not replace another such copy either
    * an `Update` is outside this rule, and keeps the behaviour it had
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Object

  @public "https://www.w3.org/ns/activitystreams#Public"
  @t0 "2026-10-01T10:00:00Z"
  @t1 "2026-10-02T10:00:00Z"
  @t2 "2026-10-03T10:00:00Z"

  setup do
    Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    n = System.unique_integer([:positive])
    id = "https://sender-#{n}.example/users/sender"
    actor(ap_id: id, data: %{"assertionMethod" => [multikey(id, new_key(:ed25519))]})

    %{sender: id, note_id: "#{id}/notes/#{n}"}
  end

  # a Create of the note, with a fresh activity id each time (the same note arriving again, not the same activity)
  defp create(sender, note_id, content, dates) do
    n = System.unique_integer([:positive])

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{sender}/activities/#{n}",
      "type" => "Create",
      "actor" => sender,
      "to" => [@public],
      "object" =>
        %{
          "id" => note_id,
          "type" => "Note",
          "attributedTo" => sender,
          "content" => content,
          "to" => [@public]
        }
        |> Map.merge(dates)
    }
  end

  defp vouched(document, sender),
    do:
      Transformer.handle_incoming(document,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: sender
      )

  defp not_vouched(document), do: Transformer.handle_incoming(document, from_inbox: true)

  defp row(ap_id) do
    {:ok, %Object{id: id}} = Object.get_cached(ap_id: ap_id)
    ActivityPub.Utils.repo().get!(Object, id)
  end

  defp content(ap_id), do: row(ap_id).data["content"]

  describe "a copy somebody vouched for" do
    test "replaces one nobody vouched for", %{sender: sender, note_id: note_id} do
      assert {:ok, _} = not_vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}))
      assert row(note_id).authenticated == :unverified

      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v2</p>", %{"published" => @t0}), sender)

      assert content(note_id) == "<p>v2</p>"
      assert row(note_id).authenticated == :http_signature
    end

    test "replaces an earlier vouched one, though not vouched the same way", %{
      sender: sender,
      note_id: note_id
    } do
      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}), sender)

      assert {:ok, _} =
               vouched(
                 create(sender, note_id, "<p>v2</p>", %{"published" => @t0, "updated" => @t1}),
                 sender
               )

      assert content(note_id) == "<p>v2</p>"
    end

    test "replaces the stored one when the dates are equal", %{sender: sender, note_id: note_id} do
      assert {:ok, _} = vouched(create(sender, note_id, "<p>v1</p>", %{"updated" => @t1}), sender)
      assert {:ok, _} = vouched(create(sender, note_id, "<p>v2</p>", %{"updated" => @t1}), sender)

      assert content(note_id) == "<p>v2</p>"
    end

    test "replaces the stored one when neither has a date", %{sender: sender, note_id: note_id} do
      assert {:ok, _} = vouched(create(sender, note_id, "<p>v1</p>", %{}), sender)
      assert {:ok, _} = vouched(create(sender, note_id, "<p>v2</p>", %{}), sender)

      assert content(note_id) == "<p>v2</p>"
    end

    test "is refused when it is provably older", %{sender: sender, note_id: note_id} do
      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v2</p>", %{"updated" => @t2}), sender)

      vouched(create(sender, note_id, "<p>v1</p>", %{"updated" => @t1}), sender)

      assert content(note_id) == "<p>v2</p>"
    end

    test "a Create delivered again after an Update does not put the old content back", %{
      sender: sender,
      note_id: note_id
    } do
      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}), sender)

      update = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{sender}/activities/update-#{System.unique_integer([:positive])}",
        "type" => "Update",
        "actor" => sender,
        "to" => [@public],
        "object" =>
          create(sender, note_id, "<p>v2, edited</p>", %{"published" => @t0, "updated" => @t2})[
            "object"
          ]
      }

      assert {:ok, _} = vouched(update, sender)
      assert content(note_id) == "<p>v2, edited</p>"

      # the original Create arrives again, as a relay or a retry would send it
      vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}), sender)

      assert content(note_id) == "<p>v2, edited</p>"
    end
  end

  describe "a copy nobody vouched for" do
    test "does not replace one somebody vouched for", %{sender: sender, note_id: note_id} do
      assert {:ok, _} =
               vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}), sender)

      not_vouched(
        create(sender, note_id, "<p>forged</p>", %{"published" => @t0, "updated" => @t2})
      )

      assert content(note_id) == "<p>v1</p>"
      assert row(note_id).authenticated == :http_signature
    end

    test "does not replace another copy nobody vouched for", %{sender: sender, note_id: note_id} do
      assert {:ok, _} = not_vouched(create(sender, note_id, "<p>v1</p>", %{"published" => @t0}))

      not_vouched(create(sender, note_id, "<p>v2</p>", %{"published" => @t0, "updated" => @t1}))

      assert content(note_id) == "<p>v1</p>"
    end
  end

  test "the same copy arriving again changes nothing", %{sender: sender, note_id: note_id} do
    assert {:ok, _} = vouched(create(sender, note_id, "<p>v1</p>", %{"updated" => @t1}), sender)
    before = row(note_id)

    vouched(create(sender, note_id, "<p>v1</p>", %{"updated" => @t1}), sender)

    assert row(note_id).data == before.data
    assert row(note_id).updated_at == before.updated_at
  end
end
