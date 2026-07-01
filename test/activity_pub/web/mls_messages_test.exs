defmodule ActivityPub.Web.MlsMessagesTest do
  @moduledoc """
  The MLS-over-ActivityPub `mls:messages` actor collection (https://purl.archive.org/socialweb/mls#messages):
  an OrderedCollection of the MLS-related activities an actor has received, so an E2EE client can
  skip scanning the whole inbox.

  Covers:
  - the actor advertises a dereferenceable `mls:messages` collection id;
  - the owner (authenticated) can read it, filtered to MLS activity/object types;
  - a non-owner gets 403;
  - the underlying query: per-type filtering matches the wrapped object's type (MLS messages are a
    `PrivateMessage`/`PublicMessage` object wrapped in a `Create`), skips the draft/`published` gate
    (so in-order MLS state can't be hidden), and matches blind addressing (`bcc`/`bto`).
  """
  use ActivityPub.Web.ConnCase, async: false
  import ActivityPub.Factory
  import Tesla.Mock
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Object
  alias ActivityPub.Utils
  alias ActivityPub.Test.HttpRequestMock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  # Insert an inbox activity (and, for wrapped types, its referenced object) addressed to `to_ap_id`.
  # opts: object_type | activity_type | published (iso8601 string, or nil to omit) | field (:to/:cc/:bto/:bcc/:audience)
  defp insert_inbox_activity(to_ap_id, opts \\ []) do
    uniq = System.unique_integer([:positive])
    base = Utils.ap_base_url()
    field = to_string(opts[:field] || :to)
    activity_type = opts[:activity_type] || "Create"

    object_ref =
      case opts[:object_type] do
        nil ->
          nil

        obj_type ->
          obj_id = "#{base}/objects/mls-obj-#{uniq}"

          {:ok, _} =
            %Object{}
            |> Ecto.Changeset.change(%{
              data: %{"id" => obj_id, "type" => obj_type, "content" => "ZmFrZQ=="},
              local: false,
              public: false,
              is_object: true
            })
            |> repo().insert()

          obj_id
      end

    data =
      %{"id" => "#{base}/objects/mls-act-#{uniq}", "type" => activity_type, field => [to_ap_id]}
      |> put_if("object", object_ref)
      |> put_if("published", Keyword.get(opts, :published, :__omit__))

    {:ok, activity} =
      %Object{}
      |> Ecto.Changeset.change(%{data: data, local: false, public: false, is_object: false})
      |> repo().insert()

    activity
  end

  defp put_if(map, _k, nil), do: map
  defp put_if(map, _k, :__omit__), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)

  defp iso(offset_seconds),
    do: DateTime.utc_now() |> DateTime.add(offset_seconds, :second) |> DateTime.to_iso8601()

  describe "actor advertisement" do
    test "actor data advertises a dereferenceable mls:messages collection id" do
      la = local_actor()

      assert la.data["mls:messages"] == "#{la.data["id"]}/mls_messages"
    end

    test "served actor JSON includes mls:messages and the mls @context prefix" do
      la = local_actor()

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/pub/actors/#{la.username}")
        |> json_response(200)

      assert resp["mls:messages"] == "#{la.data["id"]}/mls_messages"

      # the `mls` prefix must be defined in the @context so `mls:messages` expands to the canonical IRI
      assert Enum.any?(List.wrap(resp["@context"]), fn
               m when is_map(m) -> m["mls"] == "https://purl.archive.org/socialweb/mls#"
               _ -> false
             end)
    end
  end

  describe "serving GET /pub/actors/:username/mls_messages" do
    test "owner gets an OrderedCollection of only MLS activities" do
      la = local_actor()
      ap = la.data["id"]

      mls = insert_inbox_activity(ap, object_type: "PrivateMessage", published: iso(-10))
      note = insert_inbox_activity(ap, object_type: "Note", published: iso(-5))

      resp =
        build_conn()
        |> assign(:current_actor, la.actor)
        |> put_req_header("accept", "application/json")
        |> get("/pub/actors/#{la.username}/mls_messages")
        |> json_response(200)

      assert resp["type"] == "OrderedCollection"
      assert resp["id"] == "#{ap}/mls_messages"

      ids = collected_ids(resp)
      assert mls.data["id"] in ids
      refute note.data["id"] in ids
    end

    test "non-owner (unauthenticated) gets 403" do
      la = local_actor()

      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/pub/actors/#{la.username}/mls_messages")
      |> json_response(403)
    end
  end

  # pull activity ids out of either a top-level OrderedCollection (with `first` page) or a page
  defp collected_ids(resp) do
    items =
      get_in(resp, ["first", "orderedItems"]) || resp["orderedItems"] || []

    Enum.map(items, fn
      %{"id" => id} -> id
      id when is_binary(id) -> id
    end)
  end

  describe "Object.get_mls_messages_for_actor/3 and get_inbox_for_actor/3 filtering" do
    test "messages query returns only MLS-typed (wrapped-object) activities" do
      la = local_actor()
      ap = la.data["id"]

      pm = insert_inbox_activity(ap, object_type: "PrivateMessage", published: iso(-10))
      _note = insert_inbox_activity(ap, object_type: "Note", published: iso(-5))

      ids = Object.get_mls_messages_for_actor(ap) |> Enum.map(& &1.data["id"])

      assert pm.data["id"] in ids
      assert length(ids) == 1
    end

    test "messages query skips the published gate (no-published AND future-published included)" do
      la = local_actor()
      ap = la.data["id"]

      no_pub = insert_inbox_activity(ap, object_type: "PrivateMessage", published: nil)
      future = insert_inbox_activity(ap, object_type: "PrivateMessage", published: iso(3600))

      ids = Object.get_mls_messages_for_actor(ap) |> Enum.map(& &1.data["id"])

      assert no_pub.data["id"] in ids
      assert future.data["id"] in ids
    end

    test "messages query matches blind addressing (bcc/bto), not just to/cc" do
      la = local_actor()
      ap = la.data["id"]

      bcc = insert_inbox_activity(ap, object_type: "PrivateMessage", field: :bcc, published: iso(-1))

      ids = Object.get_mls_messages_for_actor(ap) |> Enum.map(& &1.data["id"])

      assert bcc.data["id"] in ids
    end

    test "regular inbox is now NULL-safe but still hides future-published posts" do
      la = local_actor()
      ap = la.data["id"]

      no_pub = insert_inbox_activity(ap, object_type: "Note", published: nil)
      future = insert_inbox_activity(ap, object_type: "Note", published: iso(3600))

      ids = Object.get_inbox_for_actor(ap) |> Enum.map(& &1.data["id"])

      assert no_pub.data["id"] in ids, "inbox should include activities with no `published` (NULL-safe fix)"
      refute future.data["id"] in ids, "inbox should still hide future-scheduled posts"
    end
  end
end
