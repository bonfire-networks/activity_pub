defmodule ActivityPub.Web.C2SOutboxAuthzTest do
  @moduledoc """
  Who may post to an actor's C2S outbox.

  The outbox belongs to the actor named in the path, so only that actor may write to it. And because the outbox POST routes share the inbox's HTTP signature pipeline, a *remote* actor can arrive authenticated, which is not a C2S client, and is refused unless the host app has explicitly delegated that signer (`maybe_delegated_user/2`, which defaults to denying).

  The delegated case is host-app policy, so it is exercised where that policy lives.
  """
  use ActivityPub.Web.ConnCase, async: false
  import ActivityPub.Factory
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Utils

  @content_type "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  setup do
    Process.put(:federating, true)
    :ok
  end

  defp outbox_endpoint(actor), do: "#{Utils.ap_base_url()}/actors/#{actor.username}/outbox"

  defp event_doc do
    %{
      "type" => "Event",
      "id" => "https://mastodon.local/event/7e57f6b1",
      "name" => "test2",
      "startTime" => "2026-08-21T15:47:13Z",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }
  end

  test "an actor may post to their own outbox", %{conn: conn} do
    alice = local_actor()

    conn =
      conn
      |> assign(:current_user, user_by_ap_id(alice))
      |> put_req_header("content-type", @content_type)
      |> post(outbox_endpoint(alice), event_doc())

    assert conn.status == 201
    assert json_response(conn, 201)["actor"] == ap_id(alice)
  end

  test "posting to another local actor's outbox is refused", %{conn: conn} do
    alice = local_actor()
    bob = local_actor()

    conn =
      conn
      |> assign(:current_user, user_by_ap_id(bob))
      |> put_req_header("content-type", @content_type)
      |> post(outbox_endpoint(alice), event_doc())

    assert conn.status == 403
  end

  test "a valid signature from a remote actor is not enough to post", %{conn: conn} do
    local = local_actor()
    remote = actor()

    conn =
      conn
      |> assign(:valid_signature, true)
      |> put_req_header("signature", "keyId=\"#{ap_id(remote)}#main-key\"")
      |> put_req_header("content-type", @content_type)
      |> post(outbox_endpoint(local), event_doc())

    assert conn.status == 403
  end

  test "posting to an outbox that belongs to nobody is a 404", %{conn: conn} do
    alice = local_actor()

    conn =
      conn
      |> assign(:current_user, user_by_ap_id(alice))
      |> put_req_header("content-type", @content_type)
      |> post("#{Utils.ap_base_url()}/actors/nobody_here_at_all/outbox", event_doc())

    assert conn.status == 404
  end
end
