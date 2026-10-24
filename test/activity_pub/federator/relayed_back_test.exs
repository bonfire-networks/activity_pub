defmodule ActivityPub.Federator.RelayedBackTest do
  @moduledoc """
  One of our own activities, relayed back to us by a group hosted elsewhere (FEP-1b12), is handed to the adapter, whatever its type, with who relayed it: what to do with it is the adapter's decision.

  Our moderation of a group hosted elsewhere may be waiting for the group, and the relayed copy is what applies it; our own post or edit was applied when we made it, and applying it again would publish it again. Only the adapter knows which is which.
  """
  use ActivityPub.DataCase, async: false
  use Repatch.ExUnit

  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Object

  @group "https://groups.example/c/group"

  setup do
    test_pid = self()

    Repatch.patch(Adapter.adapter(), :handle_activity, [mode: :shared], fn activity ->
      send(test_pid, {:handed_over, activity.data["type"], activity.relayed_by})
      {:ok, :handled}
    end)

    :ok
  end

  defp ours(type, object \\ "https://ours.example/pub/objects/post"),
    do: %Object{
      local: true,
      data: %{
        "id" => "https://ours.example/pub/objects/#{type}-#{System.unique_integer([:positive])}",
        "type" => type,
        "actor" => "https://ours.example/pub/actors/me",
        "object" => object
      }
    }

  for type <- ["Create", "Update", "Lock", "Delete", "Block"] do
    test "our own #{type} relayed back is handed to the adapter, with who relayed it" do
      assert {:ok, :handled} =
               Adapter.maybe_handle_activity(ours(unquote(type)), relayed_by: @group)

      assert_received {:handed_over, unquote(type), @group}
    end
  end

  test "the Undo of our own Lock relayed back is handed to the adapter" do
    undo = ours("Undo", %{"type" => "Lock", "object" => "https://ours.example/pub/objects/post"})

    assert {:ok, :handled} = Adapter.maybe_handle_activity(undo, relayed_by: @group)
    assert_received {:handed_over, "Undo", @group}
  end

  test "one of ours that nobody relayed is not handed over" do
    assert {:ok, :local} = Adapter.maybe_handle_activity(ours("Update"), [])
    refute_received {:handed_over, _, _}
  end
end
