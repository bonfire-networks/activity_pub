defmodule ActivityPub.Federator.WebFingerTest do
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Federator.WebFinger
  alias ActivityPub.Actor
  import ActivityPub.Factory

  import Tesla.Mock

  setup_all do
    mock_global(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "incoming webfinger request" do
    test "works for fqns" do
      actor = local_actor()

      host = WebFinger.local_hostname()

      {:ok, result} = WebFinger.finger("#{actor.username}@#{host}")

      assert is_map(result)
    end

    test "works for ap_ids" do
      actor = local_actor()
      # {:ok, ap_actor} = Actor.get_cached(username: actor.username)

      {:ok, result} = WebFinger.finger(actor.data["id"])
      assert is_map(result)
    end
  end

  describe "fingering" do
    test "works with pleroma" do
      user = "karen@mocked.local"

      {:ok, data} = WebFinger.finger(user)

      assert data["id"] == "https://mocked.local/users/karen"
    end

    test "works with mastodon" do
      user = "karen@mastodon.local"

      {:ok, data} = WebFinger.finger(user)

      assert data["id"] == "https://mastodon.local/users/admin"
    end

    test "works with mastodon, with leading @" do
      user = "@karen@mastodon.local"

      {:ok, data} = WebFinger.finger(user)

      assert data["id"] == "https://mastodon.local/users/admin"
    end
  end

  # hosts MUST be converted to IDNA A-labels before use (W3C SocialCG ActivityPub and WebFinger report, 3.1), both in the URL and in the `acct:` resource
  describe "fingering an internationalized domain" do
    for {handle, url, actor_id} <- [
          {"josé@bücher.local",
           "https://xn--bcher-kva.local/.well-known/webfinger?resource=acct%3Ajos%C3%A9%40xn--bcher-kva.local",
           "https://xn--bcher-kva.local/users/jose_u"},
          {"josé@xn--bcher-kva.local",
           "https://xn--bcher-kva.local/.well-known/webfinger?resource=acct%3Ajos%C3%A9%40xn--bcher-kva.local",
           "https://xn--bcher-kva.local/users/jose_u"},
          {"你好@你好.local",
           "https://xn--6qq79v.local/.well-known/webfinger?resource=acct%3A%E4%BD%A0%E5%A5%BD%40xn--6qq79v.local",
           "https://xn--6qq79v.local/users/nihao"},
          {"@你好@你好.local",
           "https://xn--6qq79v.local/.well-known/webfinger?resource=acct%3A%E4%BD%A0%E5%A5%BD%40xn--6qq79v.local",
           "https://xn--6qq79v.local/users/nihao"}
        ] do
      test handle do
        url = unquote(url)
        actor_id = unquote(actor_id)

        # only the A-label URL answers, so a request with a U-label host gets a 404
        mock(fn
          %{method: :get, url: ^url} ->
            json(%{
              "subject" => URI.decode_query(URI.parse(url).query)["resource"],
              "links" => [
                %{"rel" => "self", "type" => "application/activity+json", "href" => actor_id}
              ]
            })

          _ ->
            %Tesla.Env{status: 404, body: ""}
        end)

        assert {:ok, data} = WebFinger.finger(unquote(handle))
        assert data["id"] == actor_id
      end
    end
  end
end
