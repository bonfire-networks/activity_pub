# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Tests.ObanHelpers do
  @moduledoc """
  Oban test helpers.
  """

  require Ecto.Query
  import ActivityPub.Utils

  def wipe_all do
    repo().delete_all(Oban.Job)
  end

  def list_queue do
    Oban.Job
    |> Ecto.Query.where(state: "available")
    |> repo().all()
  end

  def perform_all do
    list_queue()
    |> perform()
  end

  @doc """
  Keep running queued jobs until the queue stays empty, rather than only the jobs queued right now.

  `perform_all/0` works from a single snapshot, so anything a job enqueues while running is left sitting in the queue: deleting a user, for example, enqueues the outgoing `Delete` activity from inside the deletion job, so one `perform_all/0` deletes locally and federates nothing.

  Bounded, so a job that re-enqueues itself fails the test rather than hanging it.
  """
  def drain(max_rounds \\ 10) do
    Enum.reduce_while(1..max_rounds, [], fn _round, done ->
      case perform_all() do
        [] -> {:halt, done}
        results -> {:cont, done ++ results}
      end
    end)
  end

  def perform(%Oban.Job{} = job) do
    res = apply(String.to_existing_atom("Elixir." <> job.worker), :perform, [job])
    repo().delete(job)
    res
  end

  def perform(jobs) when is_list(jobs) do
    for job <- jobs, do: perform(job)
  end

  def member?(%{} = job_args, jobs) when is_list(jobs) do
    Enum.any?(jobs, fn job ->
      member?(job_args, job.args)
    end)
  end

  def member?(%{} = test_attrs, %{} = attrs) do
    Enum.all?(
      test_attrs,
      fn {k, _v} -> member?(test_attrs[k], attrs[k]) end
    )
  end

  def member?(x, y), do: x == y
end
