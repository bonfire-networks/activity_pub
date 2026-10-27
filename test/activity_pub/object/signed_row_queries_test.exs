defmodule ActivityPub.Object.SignedRowQueriesTest do
  @moduledoc """
  A signed row holds in `data` only what changed from its original, plus the fields queries read (`always_in_patch`), so every query that reads inside `data` still finds it. Each row here is stored as a signed document with nothing changed by normalisation, the case where its `data` holds the kept fields alone.
  """
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Object

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    n = System.unique_integer([:positive])
    host = "https://signer-#{n}.local"

    %{
      host: host,
      actor: "#{host}/users/alice",
      other: "#{host}/users/bob",
      note: "#{host}/notes/#{n}"
    }
  end

  # stored as `Object.insert` stores a signed document: whole in `data`, which the changeset makes the patch over the original
  defp signed!(document, attrs \\ %{}) do
    document = Map.put(document, "proof", %{"type" => "DataIntegrityProof", "proofValue" => "z1"})

    {:ok, object} =
      %{data: document, data_received: document, local: false, public: true, is_object: false}
      |> Map.merge(attrs)
      |> Object.changeset()
      |> repo().insert()

    object
  end

  defp activity!(type, actor, object, extra \\ %{}) do
    signed!(
      Map.merge(
        %{
          "id" => "#{actor}/activities/#{System.unique_integer([:positive])}",
          "type" => type,
          "actor" => actor,
          "object" => object,
          "to" => [@public]
        },
        extra
      )
    )
  end

  defp note!(%{note: note, actor: actor}, extra \\ %{}) do
    signed!(
      Map.merge(
        %{"id" => note, "type" => "Note", "attributedTo" => actor, "to" => [@public]},
        extra
      ),
      %{is_object: true}
    )
  end

  defp ids(objects), do: Enum.map(objects, & &1.data["id"])

  test "the patch alone holds the kept fields, and nothing else", context do
    %Object{id: id} = note!(context, %{"content" => "<p>hi</p>"})

    assert %Object{data: patch} = repo().get(Object, id)
    assert Map.keys(patch) |> Enum.sort() == ["id", "to", "type"]
  end

  test "by its id", %{note: note} = context do
    note!(context)
    assert {:ok, %Object{data: %{"id" => ^note}}} = Object.get_uncached(ap_id: note)
  end

  test "by its url, when it differs from its id", %{note: note} = context do
    url = note <> "/page"
    note!(context, %{"url" => url})
    assert {:ok, %Object{data: %{"id" => ^note}}} = Object.get_uncached(ap_id: url)
  end

  test "an actor by its username", %{actor: actor} do
    signed!(%{"id" => actor, "type" => "Person", "preferredUsername" => "alice"})

    assert [%Object{data: %{"id" => ^actor}}] =
             Object.many(Object.query(username: ["alice"]))
             |> Enum.filter(&(&1.data["id"] == actor))
  end

  test "the replies to a post", %{note: note, actor: actor} do
    reply = "#{note}/reply"

    signed!(%{"id" => reply, "type" => "Note", "attributedTo" => actor, "inReplyTo" => note}, %{
      is_object: true
    })

    assert Object.replies_ids(%{data: %{"id" => note}}, 10) == [reply]
  end

  # the control: what the rows above are found by is the keep-list
  test "without the queried fields kept, a query does not find the row", %{
    actor: actor,
    note: note
  } do
    previous = Application.get_env(:activity_pub, :received_documents)
    Application.put_env(:activity_pub, :received_documents, always_in_patch: ["id"])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:activity_pub, :received_documents, previous),
        else: Application.delete_env(:activity_pub, :received_documents)
    end)

    activity!("Like", actor, note)
    assert Object.get_existing_like(actor, note) == nil
  end

  test "a like", %{actor: actor, note: note} do
    %Object{data: %{"id" => id}} = activity!("Like", actor, note)
    assert %Object{data: %{"id" => ^id}} = Object.get_existing_like(actor, note)
  end

  test "an announce", %{actor: actor, note: note} do
    %Object{data: %{"id" => id}} = activity!("Announce", actor, note)

    assert %Object{data: %{"id" => ^id}} =
             Object.get_existing_announce(actor, %{data: %{"id" => note}})
  end

  test "a flag", %{actor: actor, other: other, note: note} do
    %Object{data: %{"id" => id}} = activity!("Flag", actor, [other, note])
    assert [%Object{data: %{"id" => ^id}}] = Object.get_existing_flags(actor, note)
  end

  test "a block", %{actor: actor, other: other} do
    %Object{data: %{"id" => id}} = activity!("Block", actor, other)

    assert %Object{data: %{"id" => ^id}} =
             Object.fetch_latest_block(%{data: %{"id" => actor}}, %{data: %{"id" => other}})
  end

  test "a follow", %{actor: actor, other: other} do
    %Object{data: %{"id" => id}} = activity!("Follow", actor, other)
    assert %Object{data: %{"id" => ^id}} = Object.fetch_latest_activity(actor, other, "Follow")
  end

  test "the Create of an object", %{actor: actor, note: note} do
    %Object{data: %{"id" => id}} = activity!("Create", actor, note)
    assert %Object{data: %{"id" => ^id}} = Object.get_activity_for_object_ap_id(note)
  end

  test "an actor's outbox", %{actor: actor, note: note} do
    %Object{data: %{"id" => id}} = activity!("Create", actor, note)
    assert id in ids(Object.get_outbox_for_actor(actor))
  end

  test "an actor's inbox, by any of its addressing fields", %{
    actor: actor,
    other: other,
    note: note
  } do
    %Object{data: %{"id" => to}} = activity!("Create", actor, note, %{"to" => [other]})

    %Object{data: %{"id" => bcc}} =
      activity!("Create", actor, note, %{"to" => [], "bcc" => [other]})

    %Object{data: %{"id" => audience}} =
      activity!("Create", actor, note, %{"to" => [], "audience" => other})

    listed = ids(Object.get_inbox_for_actor(other))
    assert to in listed and bcc in listed and audience in listed
  end

  test "a second row with the same id is refused", %{note: note} = context do
    note!(context)

    assert {:error, %Ecto.Changeset{}} =
             %{
               data: %{"id" => note, "type" => "Note"},
               data_received: %{"id" => note, "type" => "Note", "proof" => %{}},
               local: false
             }
             |> Object.changeset()
             |> repo().insert()
  end
end
