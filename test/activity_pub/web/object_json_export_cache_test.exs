defmodule ActivityPub.Web.ObjectJsonExportCacheTest do
  @moduledoc """
  An account export renders each post from the `%Object{}` it already holds, without the JSON-LD `@context` header. That rendering isn't cached: there is no id to key it on, and a copy without `@context` must never be what an ordinary request for the object gets back from the cache. It used to raise inside the cache lookup for every post, which was rescued and logged as an error.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ExUnit.CaptureLog

  alias ActivityPub.Web.ActivityPubController

  test "a whole object renders without an error and without its @context" do
    activity = insert(:note_activity)

    log =
      capture_log(fn ->
        assert {:ok, json} =
                 ActivityPubController.json_object_with_cache(nil, activity,
                   exporting: true,
                   skip_json_context_header: true
                 )

        assert %{"type" => "Create"} = decoded = Jason.decode!(json)
        refute Map.has_key?(decoded, "@context")
      end)

    refute log =~ "FunctionClauseError"
  end
end
