defmodule ActivityPub.Federator.Workers.ReceiverUnverifiedWorker do
  use ActivityPub.Federator.Worker, queue: "federator_incoming_unverified"

  @impl true
  def perform_job(job), do: ActivityPub.Federator.Worker.ReceiverHelpers.perform(job, :unverified)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
end
