defmodule ActivityPub.Federator.Workers.PublisherWorker do
  use ActivityPub.Federator.Worker, queue: "federator_outgoing"
  import Untangle

  alias ActivityPub.Object
  alias ActivityPub.Federator

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"op" => "publish" = op, "activity_id" => activity_id, "repo" => repo}
      }) do
    info(activity_id, "Use queued activity to perform outgoing federation")

    ActivityPub.Utils.set_repo(repo)
    Logger.metadata(action: info(op))

    with {:ok, activity} <- Object.get_cached(id: activity_id) do
      Federator.perform(:publish, activity)
    else
      e ->
        error(e)
        raise "Could not find the activity to publish"
    end
  end

  def perform(%Oban.Job{
        args: %{"op" => "publish" = op, "activity" => activity, "repo" => repo}
      }) do
    ActivityPub.Utils.set_repo(repo)
    Logger.metadata(action: info(op))

    info(activity, "Perform outgoing federation with JSON")
    Federator.perform(:publish, activity)
  end

  def perform(%Oban.Job{
        args: %{
          "op" => "publish_one" = op,
          "module" => module_name,
          "params" => params,
          "repo" => repo
        }
      }) do
    ActivityPub.Utils.set_repo(repo)
    Logger.metadata(action: info(op))

    Federator.perform(
      :publish_one,
      String.to_atom(module_name),
      Map.new(params, fn {k, v} -> {String.to_atom(k), v} end)
    )
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
end
