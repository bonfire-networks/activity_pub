defmodule ActivityPub.PrunerThreadsTest do
  @moduledoc """
  With `keep_threads`, the pruner deletes a thread's posts only when its newest is old and none is local, the thread being the posts that share a `context`. A signed row keeps the `context` it arrived with in `data_received`, and only what normalisation changed in `data`, so the thread is read from either.
  """
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Object

  defp insert_note!(attrs, updated_at) do
    {:ok, object} =
      attrs
      |> Map.put(:local, false)
      |> Map.put(:is_object, true)
      |> Object.changeset()
      |> repo().insert()

    from(o in Object, where: o.id == ^object.id)
    |> repo().update_all(set: [updated_at: updated_at])

    object.id
  end

  defp exists?(id), do: repo().exists?(from(o in Object, where: o.id == ^id))

  test "a thread whose newest post is a recent signed one keeps its old posts" do
    n = System.unique_integer([:positive])
    context = "https://remote-#{n}.local/contexts/#{n}"

    old =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-60 * 86_400)
      |> NaiveDateTime.truncate(:second)

    recent = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    old_post =
      insert_note!(
        %{
          data: %{
            "id" => "https://remote-#{n}.local/notes/1",
            "type" => "Note",
            "actor" => "https://remote-#{n}.local/users/alice",
            "context" => context
          }
        },
        old
      )

    # a reply as received, signed: its `context` unchanged by normalisation, so not in the patch the changeset stores
    received = %{
      "id" => "https://remote-#{n}.local/notes/2",
      "type" => "Note",
      "actor" => "https://remote-#{n}.local/users/bob",
      "context" => context,
      "proof" => %{"type" => "DataIntegrityProof", "proofValue" => "z#{n}"}
    }

    reply =
      insert_note!(
        %{
          data: received,
          data_received: received
        },
        recent
      )

    ActivityPub.Pruner.prune_objects(keep_threads: true, remote_post_retention_days: 30)

    assert exists?(old_post)
    assert exists?(reply)
  end
end
