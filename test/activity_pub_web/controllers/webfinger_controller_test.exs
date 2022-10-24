defmodule ActivityPubWeb.WebFingerControllerTest do
  use ActivityPubWeb.ConnCase
  import ActivityPub.Factory
  alias ActivityPub.WebFinger

  test "webfinger with username and hostname" do
    actor = local_actor()

    response =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/.well-known/webfinger?resource=acct:#{actor.username}@#{endpoint().host()}")

    assert json_response(response, 200)["subject"] =~
             "acct:#{actor.username}@#{endpoint().host()}"
  end

  test "webfinger with username only" do
    actor = local_actor()

    response =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/.well-known/webfinger?resource=acct:#{actor.username}")

    assert json_response(response, 200)["subject"] =~
             "acct:#{actor.username}@#{endpoint().host()}"
  end

  test "webfinger with username and leading @" do
    actor = local_actor()

    response =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/.well-known/webfinger?resource=acct:@#{actor.username}")

    assert json_response(response, 200)["subject"] =~
             "acct:#{actor.username}@#{endpoint().host()}"
  end

  test "webfinger with username and hostname and leading @" do
    actor = local_actor()

    response =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/.well-known/webfinger?resource=acct:@#{actor.username}@#{endpoint().host()}")

    assert json_response(response, 200)["subject"] =~
             "acct:#{actor.username}@#{endpoint().host()}"
  end

  test "it returns 404 when user isn't found (JSON)" do
    result =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/.well-known/webfinger?resource=acct:jimm@#{endpoint().host()}")
      |> json_response(404)

    assert result == "Could not find user"
  end

  describe "incoming webfinger request" do
    test "works for fqns" do
      actor = local_actor()

      {:ok, result} = WebFinger.output("#{actor.username}@#{endpoint().host()}")

      assert is_map(result)
    end

    # test "works for ap_ids" do
    #   actor = local_actor()
    #   {:ok, ap_actor} = Actor.get_by_username(actor.username)

    #   {:ok, result} = WebFinger.output(ap_actor.data["id"])
    #   assert is_map(result)
    # end
  end
end
