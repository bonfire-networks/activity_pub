defmodule ActivityPub.Object.MergedLoadTest do
  @moduledoc """
  A signed document is stored as it arrived (`data_received`), with only what normalisation changed beside it in `data`, as a merge patch. Whatever loads such a row gets the normalised document, `data_received` with the patch applied, never the patch alone.

  Looked up here by row id: a lookup by `ap_id` reads inside `data`, which is the next step.
  """
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Object
  alias ActivityPub.Object.MergePatch

  setup do
    n = System.unique_integer([:positive])

    received = %{
      "id" => "https://signer-#{n}.local/notes/#{n}",
      "type" => "Note",
      "attributedTo" => "https://signer-#{n}.local/users/alice",
      "content" => "<p>hi</p>",
      "conversation" => "tag:signer-#{n}.local,2026:#{n}",
      "proof" => %{"type" => "DataIntegrityProof", "proofValue" => "z#{n}"}
    }

    # as normalisation would leave it: a key dropped, one added
    normalised =
      received
      |> Map.delete("conversation")
      |> Map.put("actor", received["attributedTo"])

    # `data` given whole, as every caller does: the changeset makes it the patch over the original
    {:ok, %Object{id: id}} =
      %{
        data: normalised,
        data_received: received,
        local: false,
        is_object: true
      }
      |> Object.changeset()
      |> repo().insert()

    %{id: id, received: received, normalised: normalised}
  end

  test "get_cached by row id gives the normalised document", %{id: id, normalised: normalised} do
    assert {:ok, %Object{data: ^normalised}} = Object.get_cached(id: id)
  end

  test "get_uncached by row id gives the normalised document", %{id: id, normalised: normalised} do
    assert {:ok, %Object{data: ^normalised}} = Object.get_uncached(id: id)
  end

  test "list_cached by row id gives the normalised document", %{id: id, normalised: normalised} do
    assert [%Object{data: ^normalised}] = Object.list_cached([id])
  end

  test "list_with_cache's default fetch gives the normalised document", %{
    id: id,
    normalised: normalised
  } do
    assert [%Object{data: ^normalised}] =
             ActivityPub.Utils.list_with_cache([id], :ap_object_cache, %{query_module: Object})
  end

  test "one and many give the normalised document", %{id: id, normalised: normalised} do
    assert %Object{data: ^normalised} = Object.one(Object.query(id: id))
    assert [%Object{data: ^normalised}] = Object.many(Object.query(id: [id]))
  end

  test "the original is kept as it arrived", %{id: id, received: received} do
    assert {:ok, %Object{data_received: ^received}} = Object.get_uncached(id: id)
  end

  # A loader that runs an `Object` query with `repo()` itself hands its callers the patch alone for a signed row. Each block of code (between blank lines) outside `Object` that queries `Object` and loads whole rows with `repo().all`/`repo().one` is one; selecting a column is not, as there is nothing to merge.
  test "nothing outside Object loads Object rows with repo() itself" do
    lib = Path.expand("../../../lib", __DIR__)

    offenders =
      for file <- Path.wildcard(Path.join(lib, "**/*.ex")),
          Path.basename(file) != "object.ex",
          {block, index} <- file |> File.read!() |> String.split(~r/\n\s*\n/) |> Enum.with_index(),
          String.contains?(block, ["Object.query(", " in Object", "Object\n", "Object |>"]),
          String.contains?(block, ["repo().all(", "repo().one(", "repo().all()", "repo().one()"]),
          not String.contains?(block, "select("),
          do: "#{Path.relative_to(file, lib)} (block #{index})"

    assert offenders == [],
           "load these through `Object.one/1` or `Object.many/1`, which merge a signed row's patch into its original: #{inspect(offenders)}"
  end

  test "only the patch is stored in data", %{id: id, received: received, normalised: normalised} do
    assert %Object{data: patch} = repo().get(Object, id)
    assert patch == MergePatch.create_merge_patch(received, normalised, ["id", "type", "actor"])
  end
end
