# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.ActorMigrationTest do
  @moduledoc """
  Unit repro for issue #2029: strict alsoKnownAs validation breaks following migrated accounts.

  When move/3 is called with multi-hop migrations (A→B→C) and the target's alsoKnownAs only
  lists the direct predecessor (not all ancestors), Bonfire errors with :not_in_also_known_as.
  Mastodon ignores dangling aliases; this will affect anyone who ever migrated accounts.
  """

  use ActivityPub.Web.ConnCase, async: true

  import ActivityPub.Factory
  import Tesla.Mock

  setup do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "Actor.also_known_as?/2" do
    test "returns true when ap_id is in alsoKnownAs" do
      assert ActivityPub.Actor.also_known_as?(
               "https://example.com/B",
               %{"alsoKnownAs" => ["https://example.com/B"]}
             )
    end

    test "returns false when ap_id is not in alsoKnownAs" do
      refute ActivityPub.Actor.also_known_as?(
               "https://example.com/B",
               %{"alsoKnownAs" => ["https://example.com/other"]}
             )
    end

    test "returns false when actor data has no alsoKnownAs" do
      refute ActivityPub.Actor.also_known_as?("https://example.com/B", %{
               "id" => "https://example.com/A"
             })
    end
  end

  describe "move/3 alsoKnownAs validation" do
    test "succeeds when target alsoKnownAs contains origin (normal case)" do
      origin = actor(ap_id: "https://mastodon.local/ap_api/actors/old_account")

      target =
        actor(
          ap_id: "https://mastodon.local/ap_api/actors/new_account",
          also_known_as: ["https://mastodon.local/ap_api/actors/old_account"]
        )

      assert {:ok, _} = ActivityPub.move(origin, target, false)
    end

    test "fails when target alsoKnownAs does not contain origin and no chain exists (repro #2029)" do
      origin = actor(ap_id: "https://mastodon.local/ap_api/actors/old_account_nochain")

      target =
        actor(
          ap_id: "https://mastodon.local/ap_api/actors/new_account_nochain",
          also_known_as: ["https://mastodon.local/ap_api/actors/unrelated_account"]
        )

      assert {:error, :not_in_also_known_as} = ActivityPub.move(origin, target, false)
    end

    test "succeeds for multi-hop migration A→B→C when Move(A→C) arrives and C.alsoKnownAs=[B] only (fix #2029)" do
      # A migrated to B, then B migrated to C.
      # C.alsoKnownAs = [B] (direct predecessor only — Mastodon's normal behaviour).
      # Mastodon sends Move(A→C) to redirect A's followers to C.
      # Bonfire must accept this via the transitive chain A→B→C with two-sided consent at each hop.
      a_ap_id = "https://mastodon.local/ap_api/actors/a_chain"
      b_ap_id = "https://mastodon.local/ap_api/actors/b_chain"
      c_ap_id = "https://mastodon.local/ap_api/actors/c_chain"

      # A explicitly moved to B (A consents to leave)
      _a = actor(ap_id: a_ap_id, data: %{"movedTo" => b_ap_id})
      # B accepted A (B consents), and B moved to C
      _b = actor(ap_id: b_ap_id, also_known_as: [a_ap_id], data: %{"movedTo" => c_ap_id})
      # C accepted B (C consents); C does NOT list A
      c = actor(ap_id: c_ap_id, also_known_as: [b_ap_id])

      origin = ActivityPub.Actor.get_cached!(ap_id: a_ap_id)

      refute {:error, :not_in_also_known_as} == ActivityPub.move(origin, c, false)
    end
  end
end
