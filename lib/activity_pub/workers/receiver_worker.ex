defmodule ActivityPub.Workers.ReceiverWorker do
  alias ActivityPubWeb.Federator

  use ActivityPub.Workers.WorkerHelper, queue: "federator_incoming"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"op" => "incoming_ap_doc", "params" => params}}) do
    Federator.perform(:incoming_ap_doc, params)
  end
end
