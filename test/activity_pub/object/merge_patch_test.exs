defmodule ActivityPub.Object.MergePatchTest do
  @moduledoc """
  JSON Merge Patch (RFC 7396): what normalisation changed in a received document, kept as a patch beside the document as it arrived, and applied when the row is loaded.
  """
  use ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias ActivityPub.Object
  alias ActivityPub.Object.MergePatch
  alias ActivityPub.Federator.Transformer

  @fixtures Path.expand("../../fixtures", __DIR__)

  describe "create_merge_patch/2" do
    test "is empty when nothing changed" do
      doc = %{"id" => "x", "object" => %{"content" => "hi", "tag" => [1, 2]}}
      assert MergePatch.create_merge_patch(doc, doc) == %{}
    end

    test "holds a changed leaf at its path, and nothing else" do
      assert MergePatch.create_merge_patch(
               %{"id" => "x", "object" => %{"content" => "hi", "name" => "n"}},
               %{"id" => "x", "object" => %{"content" => "hello", "name" => "n"}}
             ) == %{"object" => %{"content" => "hello"}}
    end

    test "holds an added key" do
      assert MergePatch.create_merge_patch(%{"id" => "x"}, %{"id" => "x", "summary" => ""}) ==
               %{"summary" => ""}
    end

    test "holds a removed key as nil" do
      assert MergePatch.create_merge_patch(
               %{"id" => "x", "conversation" => "tag:1", "object" => %{"a" => 1, "b" => 2}},
               %{"id" => "x", "object" => %{"a" => 1}}
             ) == %{"conversation" => nil, "object" => %{"b" => nil}}
    end

    test "holds a changed list whole, and leaves an equal one out" do
      assert MergePatch.create_merge_patch(
               %{"to" => ["a", "b"], "cc" => ["c"]},
               %{"to" => ["b", "a", "d"], "cc" => ["c"]}
             ) == %{"to" => ["b", "a", "d"]}
    end

    test "holds the new value when its shape changed" do
      received = %{"object" => %{"id" => "o"}, "actor" => "a", "attachment" => %{"url" => "u"}}

      normalised = %{
        "object" => "o",
        "actor" => %{"id" => "a"},
        "attachment" => [%{"url" => "u"}]
      }

      assert MergePatch.create_merge_patch(received, normalised) == normalised
    end
  end

  describe "create_merge_patch/3" do
    test "holds each listed key even when unchanged, and leaves the others out" do
      doc = %{"id" => "x", "type" => "Note", "content" => "hi", "to" => ["a"]}

      assert MergePatch.create_merge_patch(doc, doc, ["id", "type", "to"]) ==
               %{"id" => "x", "type" => "Note", "to" => ["a"]}
    end

    test "holds a listed key with its normalised value, whole" do
      assert MergePatch.create_merge_patch(
               %{"id" => "x", "object" => %{"id" => "o", "content" => "hi"}},
               %{"id" => "x", "object" => "o"},
               ["object"]
             ) == %{"object" => "o"}
    end

    test "holds a listed map whole, with what was taken out of it as nil, so it merges back" do
      received = %{"object" => %{"id" => "o", "content" => "hi", "proof" => %{"type" => "p"}}}
      normalised = %{"object" => %{"id" => "o", "content" => "hi"}}

      patch = MergePatch.create_merge_patch(received, normalised, ["object"])

      assert patch == %{"object" => %{"id" => "o", "content" => "hi", "proof" => nil}}
      assert MergePatch.merge_patch(received, patch) == normalised
    end

    test "does not add a listed key the normalised document has not" do
      assert MergePatch.create_merge_patch(%{"id" => "x"}, %{"id" => "x"}, ["id", "inReplyTo"]) ==
               %{"id" => "x"}
    end

    test "still removes and changes what is not listed" do
      assert MergePatch.create_merge_patch(
               %{"id" => "x", "conversation" => "tag:1", "content" => "hi"},
               %{"id" => "x", "content" => "hello"},
               ["id"]
             ) == %{"id" => "x", "conversation" => nil, "content" => "hello"}
    end

    test "merged back onto the original gives the normalised document" do
      received = %{"id" => "x", "type" => "Note", "conversation" => "tag:1", "to" => ["a"]}
      normalised = %{"id" => "x", "type" => "Note", "context" => "tag:1", "to" => ["a"]}

      patch = MergePatch.create_merge_patch(received, normalised, ["id", "type", "to"])

      assert MergePatch.merge_patch(received, patch) == normalised
    end
  end

  describe "merge_patch/2" do
    test "changes a leaf at its path and keeps the rest" do
      assert MergePatch.merge_patch(
               %{"id" => "x", "object" => %{"content" => "hi", "name" => "n"}},
               %{"object" => %{"content" => "hello"}}
             ) == %{"id" => "x", "object" => %{"content" => "hello", "name" => "n"}}
    end

    test "removes a key the patch holds as nil, at any depth" do
      assert MergePatch.merge_patch(
               %{"id" => "x", "conversation" => "tag:1", "object" => %{"a" => 1, "b" => 2}},
               %{"conversation" => nil, "object" => %{"b" => nil}}
             ) == %{"id" => "x", "object" => %{"a" => 1}}
    end

    test "replaces a list whole" do
      assert MergePatch.merge_patch(%{"to" => ["a", "b"]}, %{"to" => ["c"]}) == %{"to" => ["c"]}
    end

    test "replaces a value whose shape changed" do
      assert MergePatch.merge_patch(
               %{"object" => %{"id" => "o"}, "attachment" => %{"url" => "u"}},
               %{"object" => "o", "attachment" => [%{"url" => "u"}]}
             ) == %{"object" => "o", "attachment" => [%{"url" => "u"}]}
    end

    test "puts a map where there was none, without its nils" do
      assert MergePatch.merge_patch(%{"object" => "o"}, %{"object" => %{"id" => "o", "x" => nil}}) ==
               %{"object" => %{"id" => "o"}}
    end

    test "leaves the document as it is with an empty patch" do
      doc = %{"id" => "x", "object" => %{"a" => [1]}}
      assert MergePatch.merge_patch(doc, %{}) == doc
    end
  end

  describe "a received document and its normalised copy" do
    setup do
      # normalisation may fetch (a reply's parent, a context): nobody answers
      mock(fn _ -> %Tesla.Env{status: 404, body: ""} end)
      :ok
    end

    test "the patch of every signed fixture brings its normalised copy back" do
      signed = signed_fixtures()
      assert length(signed) > 10, "the signed fixtures were not found"

      for {path, received} <- signed do
        normalised = normalised(received)
        patch = MergePatch.create_merge_patch(received, normalised)

        # RFC 7396 cannot tell a key set to null from one removed, so a null and no key count as the same on both sides: a null the normalised copy added comes back as no key, and one the received document had (Mastodon's `"inReplyTo": null`) stays
        expected = without_nils(normalised)
        merged = without_nils(MergePatch.merge_patch(received, patch))

        assert merged == expected,
               "#{Path.relative_to(path, @fixtures)} does not come back from its patch; what is off: #{inspect(MergePatch.create_merge_patch(expected, merged))}"
      end
    end
  end

  # each fixture carrying a proof or an LD signature, as a map
  defp signed_fixtures do
    Path.wildcard(Path.join(@fixtures, "**/*.json"))
    |> Enum.flat_map(fn path ->
      case Jason.decode(File.read!(path)) do
        {:ok, %{} = doc} when is_map_key(doc, "proof") or is_map_key(doc, "signature") ->
          [{path, doc}]

        _ ->
          []
      end
    end)
  end

  # as at receipt: the actors normalised, then the embedded object fixed
  defp normalised(received) do
    received
    |> Object.normalize_actors()
    |> Transformer.fix_object()
    |> then(fn
      %{"object" => %{} = object} = activity ->
        Map.put(activity, "object", Transformer.fix_object(object))

      activity ->
        activity
    end)
  end

  defp without_nils(%{} = map),
    do: for({k, v} <- map, !is_nil(v), into: %{}, do: {k, without_nils(v)})

  defp without_nils(other), do: other
end
