# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Tests.ObanHelpers do
  @moduledoc """
  Oban test helpers.
  """

  require Ecto.Query
  import ActivityPub.Common

  def wipe_all do
    repo().delete_all(Oban.Job)
  end

  def perform_all do
    Oban.Job
    |> Ecto.Query.where(state: "available")
    |> repo().all()
    |> perform()
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
