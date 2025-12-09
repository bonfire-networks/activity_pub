defmodule ActivityPub.Federator.Workers.PublisherWorkerTest do
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Federator.Workers.PublisherWorker

  describe "maybe_schedule_worker_args/2" do
    test "sets :scheduled_at for future published date in activity" do
      now = DateTime.utc_now()
      future = DateTime.add(now, 3600, :second) |> DateTime.to_iso8601()
      params = %{"activity" => %{"published" => future}}
      args = PublisherWorker.maybe_schedule_worker_args(params, [])
      assert Keyword.has_key?(args, :scheduled_at)
      assert args[:scheduled_at] > now
    end

    test "sets :scheduled_at for future published date in activity.object" do
      now = DateTime.utc_now()
      future = DateTime.add(now, 7200, :second) |> DateTime.to_iso8601()
      params = %{"object" => %{"published" => future}}
      args = PublisherWorker.maybe_schedule_worker_args(params, [])
      assert Keyword.has_key?(args, :scheduled_at)
      assert args[:scheduled_at] > now
    end

    test "does not set :scheduled_at for published date in the past" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.to_iso8601()
      params = %{"activity" => %{"published" => past}}
      args = PublisherWorker.maybe_schedule_worker_args(params, [])
      refute Keyword.has_key?(args, :scheduled_at)
    end

    test "does not set :scheduled_at if published is missing" do
      params = %{"activity" => %{}}
      args = PublisherWorker.maybe_schedule_worker_args(params, [])
      refute Keyword.has_key?(args, :scheduled_at)
    end

    test "does not set :scheduled_at if published is not a valid ISO8601" do
      params = %{"activity" => %{"published" => "not-a-date"}}
      args = PublisherWorker.maybe_schedule_worker_args(params, [])
      refute Keyword.has_key?(args, :scheduled_at)
    end
  end
end
