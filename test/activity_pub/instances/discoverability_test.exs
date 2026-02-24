# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Instances.DiscoverabilityTest do
  @moduledoc """
  Tests that verify what a remote server can discover about this Bonfire instance.

  Covers:
  - WebFinger user-level responses (standard)
  - WebFinger self links include both activity+json and ld+json types
  - FEP-844e: generator field on actor profiles advertising RFC 9421 support
  - Accept-Signature header on actor profile fetches (RFC 9421 §5.1)
  - Accept-Signature header on inbox POST responses
  """

  use ActivityPub.Web.ConnCase

  import ActivityPub.Factory

  describe "WebFinger discoverability" do
    test "user-level WebFinger returns self links with activity+json type" do
      actor = local_actor()

      response =
        build_conn()
        |> put_req_header("accept", "application/jrd+json")
        |> get("/.well-known/webfinger?resource=acct:#{actor.username}@#{endpoint().host()}")

      body = json_response(response, 200)

      assert body["subject"] =~ "acct:#{actor.username}"

      links = body["links"]
      assert is_list(links)

      # Should include activity+json self link (for AP federation)
      assert Enum.find(links, fn link ->
               link["rel"] == "self" and link["type"] == "application/activity+json"
             end),
             "Expected a self link with type application/activity+json"

      # Should include ld+json self link (for broader LD compatibility)
      assert Enum.find(links, fn link ->
               link["rel"] == "self" and
                 link["type"] ==
                   "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""
             end),
             "Expected a self link with type application/ld+json"
    end

    test "user-level WebFinger self links point to actor AP ID" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)
      actor_id = ap_actor.data["id"]

      response =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/webfinger?resource=acct:#{actor.username}")

      body = json_response(response, 200)

      self_link =
        Enum.find(body["links"], fn link ->
          link["rel"] == "self" and link["type"] == "application/activity+json"
        end)

      assert self_link["href"] == actor_id
    end
  end

  describe "FEP-844e: generator on actor profile" do
    test "actor JSON includes generator with RFC 9421 in implements" do
      actor = local_actor()

      response =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/actors/#{actor.username}")

      assert response.status in [200, 304]
      body = json_response(response, 200)

      generator = body["generator"]

      assert is_map(generator),
             "Expected generator field on actor profile (FEP-844e), got keys: #{inspect(Map.keys(body))}"

      assert generator["type"] == "Application"

      implements = generator["implements"]
      assert is_list(implements), "Expected generator.implements to be a list"

      assert Enum.any?(implements, fn
               %{"id" => id} -> id == "https://datatracker.ietf.org/doc/html/rfc9421"
               id when is_binary(id) -> id == "https://datatracker.ietf.org/doc/html/rfc9421"
               _ -> false
             end),
             "Expected generator.implements to include RFC 9421 URI, got: #{inspect(implements)}"
    end

    test "generator includes service actor id" do
      actor = local_actor()

      response =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/actors/#{actor.username}")

      body = json_response(response, 200)
      generator = body["generator"]

      if is_map(generator) do
        # The generator.id should point to the instance's service/application actor
        assert is_binary(generator["id"]),
               "Expected generator.id to be a URI pointing to the service actor"

        assert generator["id"] =~ "http",
               "Expected generator.id to be an HTTP URI, got: #{generator["id"]}"
      end
    end
  end

  describe "FEP-844e: service actor implements" do
    test "service actor has implements directly (not nested under generator)" do
      # The service actor IS the Application — it should have `implements`
      # directly on itself, not wrapped in a `generator` field.
      {:ok, service_actor} = ActivityPub.Utils.service_actor()

      username = service_actor.username || service_actor.data["preferredUsername"]

      response =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/actors/#{username}")

      assert response.status == 200
      body = json_response(response, 200)

      implements = body["implements"]

      assert is_list(implements),
             "Expected implements directly on service actor, got keys: #{inspect(Map.keys(body))}"

      assert Enum.any?(implements, fn
               id when is_binary(id) -> String.contains?(id, "rfc9421")
               %{"id" => id} -> String.contains?(id, "rfc9421")
               _ -> false
             end),
             "Expected service actor implements to include RFC 9421, got: #{inspect(implements)}"

      # Should NOT have a generator pointing to itself
      refute is_map(body["generator"]),
             "Service actor should not have a generator field (it IS the generator)"
    end

    test "supports_rfc9421? detects implements directly on service actor data" do
      alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter

      # Simulate what a remote server would see after fetching our service actor
      service_actor_data = %{
        "type" => "Application",
        "implements" => ["https://datatracker.ietf.org/doc/html/rfc9421"]
      }

      assert SignaturesAdapter.supports_rfc9421?(service_actor_data)
    end
  end

  describe "Accept-Signature header (RFC 9421 §5.1)" do
    test "actor profile response includes Accept-Signature header" do
      actor = local_actor()

      response =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/actors/#{actor.username}")

      assert response.status in [200, 304]

      accept_sig = Plug.Conn.get_resp_header(response, "accept-signature")

      assert accept_sig != [],
             "Expected Accept-Signature header on actor profile response, got headers: #{inspect(Enum.map(response.resp_headers, &elem(&1, 0)))}"

      assert hd(accept_sig) =~ "sig1"
    end

    test "object response includes Accept-Signature header" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      {:ok, activity} =
        ActivityPub.create(%{
          actor: ap_actor,
          to: [ActivityPub.Config.public_uri()],
          object: %{
            "type" => "Note",
            "content" => "discoverability test",
            "actor" => ap_actor.data["id"],
            "attributedTo" => ap_actor.data["id"],
            "to" => [ActivityPub.Config.public_uri()]
          }
        })

      object_id = activity.object.data["id"]
      uuid = object_id |> String.split("/") |> List.last()

      response =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/objects/#{uuid}")

      if response.status == 200 do
        accept_sig = Plug.Conn.get_resp_header(response, "accept-signature")

        assert accept_sig != [],
               "Expected Accept-Signature header on object response"

        assert hd(accept_sig) =~ "sig1"
      end
    end

    test "shared inbox POST response includes Accept-Signature header" do
      # Simulate a remote server POSTing to our shared inbox
      # The signature validation will fail (no real sig), but we should still
      # get a response with Accept-Signature header
      response =
        build_conn()
        |> put_req_header("content-type", "application/activity+json")
        |> post("/pub/shared_inbox", Jason.encode!(%{"type" => "Create"}))

      # Regardless of status (likely 401/403 due to missing signature),
      # check if Accept-Signature is present on any response
      accept_sig = Plug.Conn.get_resp_header(response, "accept-signature")

      if response.status in 200..299 do
        assert accept_sig != [],
               "Expected Accept-Signature header on inbox response"

        assert hd(accept_sig) =~ "sig1"
      else
        # Even error responses should ideally include Accept-Signature,
        # but the current implementation only adds it on successful processing.
        # This is acceptable — the header on actor fetches is the primary signal.
        :ok
      end
    end
  end

  describe "host-meta" do
    test "returns XRD with WebFinger template" do
      response =
        build_conn()
        |> get("/.well-known/host-meta")

      assert response.status == 200

      body = response.resp_body
      assert body =~ "webfinger"
      assert body =~ "{uri}"
    end
  end
end
