defmodule ActivityPub.Object.MergePatch do
  @moduledoc """
  JSON Merge Patch ([RFC 7396](https://www.rfc-editor.org/rfc/rfc7396)) on decoded JSON: `create_merge_patch/2` gives what changed from one document to another, and `merge_patch/2` applies it.

  A map is patched key by key, at any depth. A key the patch holds as `nil` is removed. Anything else (a list, a scalar, a value whose shape changed) is replaced whole: a list's positions are no identity, so it is never patched by element. As in the RFC, a key set to `null` cannot be told from one removed, so it comes back as no key.

  Used to keep a received document as it arrived (so its proof or signature still verifies) with only what normalisation changed beside it.
  """

  @doc """
  What changed from `from` to `to`, as a merge patch: each changed or added value at its path, each removed key as `nil`. `%{}` when nothing changed.

      iex> create_merge_patch(%{"a" => 1, "b" => %{"c" => 2, "d" => 3}}, %{"a" => 1, "b" => %{"c" => 4}})
      %{"b" => %{"c" => 4, "d" => nil}}
  """
  def create_merge_patch(%{} = from, %{} = to) do
    removed = for key <- Map.keys(from), not is_map_key(to, key), into: %{}, do: {key, nil}

    Enum.reduce(to, removed, fn {key, value}, patch ->
      case from do
        %{^key => ^value} -> patch
        %{^key => %{} = old} when is_map(value) -> Map.put(patch, key, create_merge_patch(old, value))
        _ -> Map.put(patch, key, value)
      end
    end)
  end

  def create_merge_patch(_from, to), do: to

  @doc """
  `patch` applied to `target`, walking the patch only, so the cost grows with the patch rather than the document. A map patched onto something that is not a map starts from an empty one.

      iex> merge_patch(%{"a" => 1, "b" => %{"c" => 2, "d" => 3}}, %{"b" => %{"c" => 4, "d" => nil}})
      %{"a" => 1, "b" => %{"c" => 4}}
  """
  def merge_patch(target, %{} = patch) do
    Enum.reduce(patch, if(is_map(target), do: target, else: %{}), fn
      {key, nil}, acc -> Map.delete(acc, key)
      {key, %{} = sub_patch}, acc -> Map.put(acc, key, merge_patch(Map.get(acc, key), sub_patch))
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  def merge_patch(_target, patch), do: patch
end
