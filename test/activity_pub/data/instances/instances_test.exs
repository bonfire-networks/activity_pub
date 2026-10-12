defmodule ActivityPub.InstancesTest do
  use ActivityPub.DataCase

  alias ActivityPub.Instances

  setup_all do
    config_path = [:instance, :federation_reachability_timeout_days]
    initial_setting = ActivityPub.Config.get(config_path)

    ActivityPub.Config.put(config_path, 1)
    on_exit(fn -> ActivityPub.Config.put(config_path, initial_setting) end)

    # the probe tests count in days against these
    for {key, value} <- [
          federation_dead_probe_fraction: 10,
          federation_dead_probe_cap_sec: 7 * 86_400
        ] do
      initial = ActivityPub.Config.get([:instance, key])
      ActivityPub.Config.put([:instance, key], value)
      on_exit(fn -> ActivityPub.Config.put([:instance, key], initial) end)
    end

    :ok
  end

  describe "reachable?/1" do
    test "returns `true` for host / url with unknown reachability status" do
      assert Instances.reachable?("unknown.local")
      assert Instances.reachable?("http://unknown.local")
    end

    test "returns `false` for host / url marked unreachable for at least `reachability_datetime_threshold()`" do
      host = "consistently-unreachable.name"
      Instances.set_consistently_unreachable(host)

      refute Instances.reachable?(host)
      refute Instances.reachable?("http://#{host}/path")
    end

    test "returns `true` for host / url marked unreachable for less than `reachability_datetime_threshold()`" do
      url = "http://eventually-unreachable.local/path"

      Instances.set_unreachable(url)

      assert Instances.reachable?(url)
      assert Instances.reachable?(URI.parse(url).host)
    end

    test "returns `true` for host / url past the threshold once it is due a probe" do
      host = "long-unreachable.local"
      written_off_for(host, 30, 4)

      assert Instances.reachable?(host),
             "nothing else ever contacts a host we have given up on, so without a probe a host that recovers stays blocked forever"
    end

    test "returns `false` for host / url past the threshold that was probed too recently" do
      host = "long-unreachable.local"
      written_off_for(host, 30, 2)

      refute Instances.reachable?(host),
             "down for 30 days, so it waits 3 days between probes, and the last one was 2 days ago"
    end

    test "waits longer between probes the longer the host has been failing, up to the cap" do
      host = "long-unreachable.local"

      written_off_for(host, 300, 10)

      assert Instances.reachable?(host),
             "the wait is capped at a week, however long the host has been down"

      written_off_for(host, 300, 5)

      refute Instances.reachable?(host),
             "down for 300 days, so a week between probes, not the 3 days of a 30-day outage"
    end

    test "returns falsy on non-binary input" do
      refute Instances.reachable?(nil)
      refute Instances.reachable?(1)
    end
  end

  describe "filter_reachable/1" do
    setup do
      host = "consistently-unreachable.name"
      url1 = "http://eventually-unreachable.local/path"
      url2 = "http://domain.local/path"

      Instances.set_consistently_unreachable(host)
      Instances.set_unreachable(url1)

      result = Instances.filter_reachable([host, url1, url2, nil])
      %{result: result, url1: url1, url2: url2}
    end

    test "returns a map with keys containing 'not marked consistently unreachable' elements of supplied list",
         %{result: result, url1: url1, url2: url2} do
      assert is_map(result)
      assert Enum.sort([url1, url2]) == result |> Map.keys() |> Enum.sort()
    end

    test "returns a map with `unreachable_since` values for keys",
         %{result: result, url1: url1, url2: url2} do
      assert is_map(result)
      assert %NaiveDateTime{} = result[url1]
      assert is_nil(result[url2])
    end

    test "returns an empty map for empty list or list containing no hosts / url" do
      assert %{} == Instances.filter_reachable([])
      assert %{} == Instances.filter_reachable([nil])
    end
  end

  describe "filter_reachable/1 with a written-off host" do
    @url "http://long-unreachable.local/inbox"

    test "keeps it once it is due a probe, with its `unreachable_since`, so the delivery is the probe" do
      written_off_for("long-unreachable.local", 30, 4)

      assert %NaiveDateTime{} = Instances.filter_reachable([@url])[@url],
             "deliveries are the only traffic to a host nobody here follows, so dropping them all means it is never probed"
    end

    test "drops it while it was probed too recently" do
      written_off_for("long-unreachable.local", 30, 2)

      assert %{} == Instances.filter_reachable([@url])
    end
  end

  describe "dead_probe_sec/1" do
    test "grows with how long the host has been failing" do
      assert Instances.dead_probe_sec(30 * 86_400) > Instances.dead_probe_sec(15 * 86_400)
    end

    test "and stops growing at the cap" do
      assert Instances.dead_probe_sec(300 * 86_400) == Instances.dead_probe_sec(3000 * 86_400),
             "the cap is the longest a host that recovers can go unnoticed"
    end
  end

  # sets both halves the probe decision reads: how long the host has been failing, and when we last tried it
  defp written_off_for(host, days, last_attempt_days_ago) do
    now = NaiveDateTime.utc_now(Calendar.ISO) |> NaiveDateTime.truncate(:second)

    Instances.set_unreachable(host)

    repo().update_all(
      Ecto.Query.from(i in ActivityPub.Instances.Instance, where: i.host == ^host),
      set: [
        unreachable_since: NaiveDateTime.add(now, -days * 86_400),
        updated_at: NaiveDateTime.add(now, -last_attempt_days_ago * 86_400)
      ]
    )
  end

  describe "set_reachable/1" do
    test "sets unreachable url or host reachable" do
      host = "domain.local"
      Instances.set_consistently_unreachable(host)
      refute Instances.reachable?(host)

      Instances.set_reachable(host)
      Process.sleep(500)
      assert Instances.reachable?(host)
    end

    test "keeps reachable url or host reachable" do
      url = "https://site.local?q="
      assert Instances.reachable?(url)

      Instances.set_reachable(url)
      assert Instances.reachable?(url)
    end

    test "returns error status on non-binary input" do
      assert {:error, _} = Instances.set_reachable(nil)
      assert {:error, _} = Instances.set_reachable(1)
    end
  end

  # Note: implementation-specific (e.g. Instance) details of set_unreachable/1
  # should be tested in implementation-specific tests
  describe "set_unreachable/1" do
    test "returns error status on non-binary input" do
      assert {:error, _} = Instances.set_unreachable(nil)
      assert {:error, _} = Instances.set_unreachable(1)
    end
  end

  describe "set_consistently_unreachable/1" do
    test "sets reachable url or host unreachable" do
      url = "http://domain.local?q="
      assert Instances.reachable?(url)

      Instances.set_consistently_unreachable(url)
      refute Instances.reachable?(url)
    end

    test "keeps unreachable url or host unreachable" do
      host = "site.local"
      Instances.set_consistently_unreachable(host)
      refute Instances.reachable?(host)

      Instances.set_consistently_unreachable(host)
      refute Instances.reachable?(host)
    end
  end
end
