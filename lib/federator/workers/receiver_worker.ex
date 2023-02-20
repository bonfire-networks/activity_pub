defmodule ActivityPub.Federator.Workers.ReceiverWorker do
  use ActivityPub.Federator.Worker, queue: "federator_incoming"
  import Untangle
  alias ActivityPub.Federator

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"op" => "incoming_ap_doc" = op, "params" => params, "repo" => repo}
      }) do
    ActivityPub.Utils.set_repo(repo)
    Logger.metadata(action: info(op))
    Federator.perform(:incoming_ap_doc, params)
  end
end
