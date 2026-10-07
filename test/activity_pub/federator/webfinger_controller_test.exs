defmodule ActivityPub.Web.WebFingerControllerTest do
  use ActivityPub.Web.ConnCase
  import ActivityPub.Factory
  alias ActivityPub.Federator.WebFinger

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

  # handles may carry a type prefix, e.g. `&` for groups or `+` for topics
  for prefix <- ["@", "&", "+"] do
    test "webfinger with a #{prefix} prefix on the username" do
      actor = local_actor()

      response =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get(
          "/.well-known/webfinger?" <>
            URI.encode_query(%{
              "resource" => "acct:#{unquote(prefix)}#{actor.username}@#{endpoint().host()}"
            })
        )

      assert json_response(response, 200)["subject"] =~
               "acct:#{actor.username}@#{endpoint().host()}"
    end
  end

  describe "a resource whose username is not exactly a local username returns 404" do
    # each case has a local user whose name is a part of the requested one, which a partial match would serve instead
    for {local_username, requested} <- [
          {"jos", "josé"},
          {"jos", "jos.extra"},
          {"xyz", "你好xyz"}
        ] do
      test "#{requested} (with local user #{local_username})" do
        actor = local_actor(%{username: unquote(local_username)})
        assert actor.username == unquote(local_username)

        # the local user itself is found, so the 404s below are about the requested name
        assert build_conn()
               |> put_req_header("accept", "application/json")
               |> get(
                 "/.well-known/webfinger?resource=acct:#{actor.username}@#{endpoint().host()}"
               )
               |> json_response(200)

        for resource <- [
              "acct:#{unquote(requested)}@#{endpoint().host()}",
              "acct:#{unquote(requested)}"
            ] do
          result =
            build_conn()
            |> put_req_header("accept", "application/json")
            |> get("/.well-known/webfinger?" <> URI.encode_query(%{"resource" => resource}))
            |> json_response(404)

          assert result == "Could not find user"
        end
      end
    end
  end

  describe "incoming webfinger request" do
    test "works for fqns" do
      actor = local_actor()

      {:ok, result} = WebFinger.output("#{actor.username}@#{endpoint().host()}")

      assert is_map(result)
    end

    # test "works for ap_ids" do
    #   actor = local_actor()
    #   {:ok, ap_actor} = Actor.get_cached(username: actor.username)

    #   {:ok, result} = WebFinger.output(ap_actor.data["id"])
    #   assert is_map(result)
    # end
  end
end
