# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.FEP844eTest do
  @moduledoc "Tests for FEP-844e capability discovery via actor generator.implements"

  use ActivityPub.Web.ConnCase, async: false
  import ActivityPub.Factory
  import Tesla.Mock
  import Phoenix.ConnTest

  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Utils

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  describe "actor generator (FEP-844e)" do
    test "actor JSON-LD includes generator context, and generator with implements list" do
      actor = local_actor()

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/pub/actors/#{actor.username}")
        |> json_response(200)

      generator = resp["generator"]
      assert generator, "actor should include generator property"
      assert generator["type"] == "Application"
      assert is_list(generator["implements"])

      assert Enum.any?(generator["implements"], fn
               %{"href" => href} -> href == "https://datatracker.ietf.org/doc/html/rfc9421"
               uri when is_binary(uri) -> uri == "https://datatracker.ietf.org/doc/html/rfc9421"
               _ -> false
             end),
             "Expected implements to include RFC 9421 URI"

      assert Enum.any?(generator["implements"], fn
               %{"href" => href} -> href == "https://www.w3.org/TR/activitypub/"
               uri when is_binary(uri) -> uri == "https://www.w3.org/TR/activitypub/"
               _ -> false
             end),
             "Expected implements to include ActivityPub URI"

      # check for context term for FEP-844e
      context = resp["@context"]
      assert is_list(context)

      # The implements term should be in one of the context maps
      context_maps = Enum.filter(context, &is_map/1)

      assert Enum.any?(context_maps, fn map ->
               case map["implements"] do
                 %{"@id" => "https://w3id.org/fep/844e#implements"} -> true
                 _ -> false
               end
             end),
             "actor @context should include FEP-844e implements term"
    end
  end
end
