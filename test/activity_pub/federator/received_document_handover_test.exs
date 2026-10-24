defmodule ActivityPub.Federator.ReceivedDocumentHandoverTest do
  @moduledoc """
  The document as it reached our inbox (`data_received:`) travels with a delivery to the adapter, which needs it to relay the activity unchanged (a group's Announce of it, FEP-1b12).

    * the receiver puts it in the options of every delivery it hands on
    * an adapter with `handle_activity/2` gets it in its options; one with only `handle_activity/1` is called as before
    * whoever uses it checks it is the activity at hand (`ActivityPub.announce/2` does, see `relayed_received_document_test.exs`): the inner activity of a relayed Announce is handed over with the Announce's
  """
  use ActivityPub.DataCase, async: false
  use Repatch.ExUnit

  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Federator.Worker.ReceiverHelpers
  alias ActivityPub.Object

  defmodule TwoArity do
    def handle_activity(activity, opts),
      do: send(self(), {:handed_over, activity.data["id"], opts[:data_received]}) && {:ok, :two}
  end

  defmodule OneArity do
    def handle_activity(activity),
      do: send(self(), {:handed_over, activity.data["id"]}) && {:ok, :one}
  end

  defmodule CarriedOnTheActivity do
    def handle_activity(activity),
      do: send(self(), {:on_the_activity, activity.data_received}) && {:ok, :one}
  end

  defp with_adapter(adapter) do
    previous = Application.get_env(:activity_pub, :adapter)
    Application.put_env(:activity_pub, :adapter, adapter)
    on_exit(fn -> Application.put_env(:activity_pub, :adapter, previous) end)
  end

  defp remote(id), do: %Object{local: false, data: %{"id" => id, "type" => "Update"}}

  @document %{
    "id" => "https://elsewhere.example/activities/1",
    "type" => "Update",
    "proof" => %{}
  }

  describe "the adapter" do
    test "with handle_activity/2 gets the received document of the activity" do
      with_adapter(TwoArity)

      assert {:ok, :two} =
               Adapter.maybe_handle_activity(remote(@document["id"]), data_received: @document)

      assert_received {:handed_over, id, @document}
      assert id == @document["id"]
    end

    test "with only handle_activity/1 is called as before" do
      with_adapter(OneArity)

      assert {:ok, :one} =
               Adapter.maybe_handle_activity(remote(@document["id"]), data_received: @document)

      assert_received {:handed_over, _id}
    end

    test "gets it on the activity too, so it reaches whatever the activity is passed to (a group's Announce of it)" do
      with_adapter(CarriedOnTheActivity)

      assert {:ok, :one} =
               Adapter.maybe_handle_activity(remote(@document["id"]), data_received: @document)

      assert_received {:on_the_activity, @document}
    end
  end

  test "the receiver hands on the document it received" do
    test_pid = self()

    Repatch.patch(Transformer, :handle_incoming, [mode: :shared], fn params, opts ->
      send(test_pid, {:data_received, opts[:data_received], params})
      {:ok, :handled}
    end)

    params = %{"id" => "https://elsewhere.example/activities/2", "type" => "Like"}

    ReceiverHelpers.perform(
      # as the worker enqueues it
      %Oban.Job{
        args: %{"op" => "incoming_ap_doc", "params" => params, "repo" => ActivityPub.Utils.repo()}
      },
      :verified
    )

    assert_received {:data_received, ^params, ^params}
  end
end
