defmodule ActivityPub.Object.IndexesTest do
  @moduledoc """
  The frequent lookups on `ap_object` that read inside `data` each have an index matching the expression the query is built with. A query and its index that drift apart still return the right rows, but by scanning the whole table: on an instance with a million rows, an outbox page takes about 200 ms instead of under 1 ms, and a lookup by username about 300 ms.

  Each case runs the real query, captures its SQL from the repo's query telemetry, and asks Postgres how it would run it:
  - as a generic plan (`EXPLAIN (GENERIC_PLAN)`), which is what Postgres may switch to after a statement has run five times, and where a parameter's value cannot be used to match a partial index
  - with sequential scans disabled, as on a small test table the planner would otherwise scan whatever indexes exist
  """
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Object

  setup do
    test_pid = self()
    handler = "indexes-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      repo().config()[:telemetry_prefix] ++ [:query],
      &__MODULE__.send_query/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    n = System.unique_integer([:positive])
    %{actor: "https://indexed-#{n}.local/users/alice", username: "alice_#{n}"}
  end

  describe "an actor's outbox" do
    test "a page reads the actor index", %{actor: actor} do
      Object.get_outbox_for_actor(actor)

      assert_plan_uses(&outbox_page?/1, "ap_object_actor_inserted_at_index")
    end

    test "its count reads the actor index", %{actor: actor} do
      Object.count_outbox_for_actor(actor)

      assert_plan_uses(&outbox_count?/1, "ap_object_actor_inserted_at_index")
    end
  end

  describe "an actor's inbox" do
    test "a page reads the recipients index", %{actor: actor} do
      Object.get_inbox_for_actor(actor)

      assert_plan_uses(&inbox_page?/1, "ap_object_recipients_index")
    end

    test "its count reads the recipients index", %{actor: actor} do
      Object.count_inbox_for_actor(actor)

      assert_plan_uses(&inbox_count?/1, "ap_object_recipients_index")
    end

    test "its MLS messages read the recipients index", %{actor: actor} do
      Object.get_mls_messages_for_actor(actor)

      assert_plan_uses(&inbox_page?/1, "ap_object_recipients_index")
    end
  end

  describe "the pruner's daily deletes" do
    for {type, prune} <- [
          {"Delete", :prune_deletes},
          {"Undo", :prune_undos},
          {"Remove", :prune_removes},
          {"Tombstone", :prune_tombstones},
          {"Follow", :prune_stale_follow_requests}
        ] do
      test "of old #{type} rows read the pruner index" do
        apply(ActivityPub.Pruner, unquote(prune), [nil])

        assert_plan_uses(&pruning?(&1, unquote(type)), "ap_object_prunable_updated_at_index")
      end
    end
  end

  describe "a lookup by username" do
    test "of a local actor's tombstone reads the username index", %{username: username} do
      Object.get_uncached(username: username, local: true)

      assert_plan_uses(&by_username?/1, "ap_object_preferred_username_index")
    end

    test "of a batch of actors reads the username index", %{username: username} do
      Object.many(Object.query(username: [username]))

      assert_plan_uses(&by_username?/1, "ap_object_preferred_username_index")
    end
  end

  def send_query(_event, _measurements, %{query: sql}, test_pid), do: send(test_pid, {:sql, sql})

  defp outbox_page?(sql), do: sql =~ "'actor'" and sql =~ "ORDER BY" and not (sql =~ "count(")
  defp outbox_count?(sql), do: sql =~ "'actor'" and sql =~ "count("
  defp inbox_page?(sql), do: sql =~ "'audience'" and sql =~ "ORDER BY" and not (sql =~ "count(")
  defp inbox_count?(sql), do: sql =~ "'audience'" and sql =~ "count("
  defp pruning?(sql, type), do: sql =~ "DELETE" and sql =~ "'#{type}'"
  defp by_username?(sql), do: sql =~ "'preferredUsername'"

  defp assert_plan_uses(which?, index) do
    sql =
      captured_sql()
      |> Enum.find(which?) ||
        flunk("the query was not run, or no longer reads the field it is indexed by")

    repo().query!("SET LOCAL enable_seqscan = off")

    # the simple protocol, which leaves the `$1…` placeholders unbound, as a generic plan wants them
    plan =
      repo().query!("EXPLAIN (GENERIC_PLAN) " <> sql, [], query_type: :text).rows
      |> Enum.map_join("\n", &hd/1)

    assert plan =~ index, "expected the plan to use #{index}:\n#{sql}\n\n#{plan}"
  end

  defp captured_sql(acc \\ []) do
    receive do
      {:sql, sql} -> captured_sql([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
