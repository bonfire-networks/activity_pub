defmodule ActivityPub.Federator.Workers.PublisherWorker do
  use ActivityPub.Federator.Worker, queue: "federator_outgoing"
  import Untangle

  alias ActivityPub.Object
  alias ActivityPub.Federator

  @impl true
  def perform_job(%Oban.Job{
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

  def perform_job(%Oban.Job{
        args: %{"op" => "publish" = op, "activity" => activity, "repo" => repo}
      }) do
    ActivityPub.Utils.set_repo(repo)
    Logger.metadata(action: info(op))

    info(activity, "Perform outgoing federation with JSON")
    Federator.perform(:publish, activity)
  end

  def perform_job(%Oban.Job{
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

  @doc """
  Returns worker args with Oban's `scheduled_at` set if the activity's published date is in the future.

  ## Examples

      iex> now = DateTime.utc_now()
      iex> future = DateTime.add(now, 3600, :second) |> DateTime.to_iso8601()
      iex> params = %{"object" => %{"published" => future}}
      iex> ActivityPub.Federator.Workers.PublisherWorker.maybe_schedule_worker_args(params, []) |> Keyword.has_key?(:scheduled_at)
      true

      iex> params = %{"published" => DateTime.utc_now() |> DateTime.to_iso8601()}
      iex> ActivityPub.Federator.Workers.PublisherWorker.maybe_schedule_worker_args(params, [])
      []
  """
  def maybe_schedule_worker_args(%{"published" => published}, worker_args)
      when is_binary(published) do
    with {:ok, dt, _} <- DateTime.from_iso8601(published),
         true <- DateTime.compare(dt, DateTime.utc_now()) == :gt do
      Keyword.put(worker_args, :scheduled_at, dt)
    else
      _ -> worker_args
    end
  end

  def maybe_schedule_worker_args(%{"object" => %{"published" => published} = object}, worker_args)
      when is_binary(published) do
    maybe_schedule_worker_args(object, worker_args)
  end

  def maybe_schedule_worker_args(%{"activity" => %{} = activity}, worker_args) do
    maybe_schedule_worker_args(activity, worker_args)
  end

  def maybe_schedule_worker_args(_, worker_args) do
    worker_args
  end
end
