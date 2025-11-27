defmodule ActivityPub.Federator.Workers.ReceiverFollowsWorker do
  use ActivityPub.Federator.Worker, queue: "federator_incoming_follows"

  @impl Oban.Worker
  def perform(job), do: ActivityPub.Federator.Worker.ReceiverHelpers.perform(job, :follows)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
end
