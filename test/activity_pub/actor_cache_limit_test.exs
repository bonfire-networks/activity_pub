defmodule ActivityPub.ActorCacheLimitTest do
  @moduledoc """
  T7 (team-docs/plans/ap-followers-collections-tdd.md): the `:ap_actor_cache` size cap must be
  configurable (`config :activity_pub, :actor_cache_limit`) instead of a hard-coded 2_500 — each
  actor occupies 4 keys, so the cap must be tunable per instance size.

  Tests the child-spec builder rather than restarting the cache in-VM.
  """
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:activity_pub, :actor_cache_limit)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:activity_pub, :actor_cache_limit, previous),
        else: Application.delete_env(:activity_pub, :actor_cache_limit)
    end)

    :ok
  end

  defp actor_cache_limit_from_spec do
    %{start: {Cachex, :start_link, [:ap_actor_cache, opts]}} =
      ActivityPub.Application.cachex()
      |> Enum.find(&(&1.id == :ap_actor_cache))

    # `Cachex.Spec.hook` is `record(:hook, module:, args:, name:)` → `{:hook, module, args, name}`
    opts[:hooks]
    |> Enum.find_value(fn
      {:hook, Cachex.Limit.Scheduled, {limit, _, _}, _name} when is_integer(limit) -> limit
      _ -> nil
    end)
  end

  test "the Cachex.Limit.Scheduled cap for :ap_actor_cache follows config" do
    Application.put_env(:activity_pub, :actor_cache_limit, 7)
    assert actor_cache_limit_from_spec() == 7
  end

  test "the default cap is well above the old 2_500 (4 keys per actor)" do
    Application.delete_env(:activity_pub, :actor_cache_limit)
    limit = actor_cache_limit_from_spec()
    assert is_integer(limit) and limit >= 20_000
  end
end
