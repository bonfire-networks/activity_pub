defmodule ActivityPubWeb.WebFingerControllerTest do
  use ActivityPubWeb.ConnCase
  import ActivityPub.Factory

  test "webfinger" do
    actor = local_actor()

    response =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/.well-known/webfinger?resource=acct:#{actor.username}@localhost")

    assert json_response(response, 200)["subject"] == "acct:#{actor.username}@localhost"
  end

  test "it returns 404 when user isn't found (JSON)" do
    result =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/.well-known/webfinger?resource=acct:jimm@localhost")
      |> json_response(404)

    assert result == "Couldn't find user"
  end
end
