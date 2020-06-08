# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Workers.WorkerHelper do
  alias MoodleNet.Config
  alias ActivityPub.Workers.WorkerHelper

  def worker_args(queue) do
    case Config.get([:workers, :retries, queue]) do
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
        max_attempts: 1

      def enqueue(op, params, worker_args \\ []) do
        params = Map.merge(%{"op" => op}, params)
        queue_atom = String.to_atom(unquote(queue))
        worker_args = worker_args ++ WorkerHelper.worker_args(queue_atom)

        unquote(caller_module)
        |> apply(:new, [params, worker_args])
        |> MoodleNet.Repo.insert()
      end
    end
  end
end
