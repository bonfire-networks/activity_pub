defmodule ActivityPub.Federator.Workers.ReceiverWorker do
  use ActivityPub.Federator.Worker, queue: "federator_incoming"

  @impl Oban.Worker
  def perform(job), do: ActivityPub.Federator.Worker.ReceiverHelpers.perform(job, :verified)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
end
