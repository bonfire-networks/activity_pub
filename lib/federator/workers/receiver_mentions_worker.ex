defmodule ActivityPub.Federator.Workers.ReceiverMentionsWorker do
  use ActivityPub.Federator.Worker, queue: "federator_incoming_mentions"

  @impl true
  def perform_job(job), do: ActivityPub.Federator.Worker.ReceiverHelpers.perform(job, :mentions)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
end
