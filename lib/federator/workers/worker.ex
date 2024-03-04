defmodule ActivityPub.Federator.Worker do
  @moduledoc "Helpers for workers to `use`"

  alias ActivityPub.Config

  def worker_args(queue) do
    case Config.get([:oban_queues, :retries, queue], 3) do
      nil -> []
      max_attempts -> [max_attempts: max_attempts]
    end
  end

  defmacro __using__(opts) do
    caller_module = __CALLER__.module
    queue = Keyword.fetch!(opts, :queue)

    quote do
      # Note: `max_attempts` is intended to be overridden in `new/2` call
      use Oban.Worker,
        queue: unquote(queue),
        max_attempts: 3

      def enqueueable(op, params, worker_args \\ []) do
        params = Map.merge(%{"op" => op, "repo" => ActivityPub.Utils.repo()}, params)
        queue_atom = String.to_atom(unquote(queue))

        worker_args =
          worker_args ++
            ActivityPub.Federator.Worker.worker_args(queue_atom)

        unquote(caller_module).new(params, worker_args)
      end

      def enqueue(op, params, worker_args \\ []) do
        Oban.insert(enqueueable(op, params, worker_args || []))
      end
    end
  end
end
