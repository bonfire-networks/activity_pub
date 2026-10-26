defmodule ActivityPub.Object.DataReceivedColumnTest do
  @moduledoc """
  A signed document is stored as it arrived (`data_received`), with only what normalisation changed beside it in `data`, as a merge patch (`ActivityPub.Object.MergePatch`), which is `%{}` when nothing changed.
  """
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Object

  test "a row holds the document as it arrived next to its patch, and reads both back" do
    received = %{
      "id" => "https://signer.local/notes/#{System.unique_integer([:positive])}",
      "type" => "Note",
      "content" => "<p>hi</p>",
      "proof" => %{"type" => "DataIntegrityProof", "proofValue" => "z123"}
    }

    assert {:ok, %Object{id: id}} =
             %{data: %{}, data_received: received, local: false}
             |> Object.changeset()
             |> repo().insert()

    assert %Object{data: %{}, data_received: ^received} = repo().get(Object, id)
  end

  test "a row without one has none" do
    assert {:ok, %Object{id: id}} =
             %{data: %{"id" => "https://plain.local/notes/1", "type" => "Note"}, local: false}
             |> Object.changeset()
             |> repo().insert()

    assert %Object{data_received: nil} = repo().get(Object, id)
  end
end
