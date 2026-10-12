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

  # the examples from https://swicg.github.io/activitypub-webfinger/internationalized: in an `acct:` URI the userpart is percent-encoded and the host is an IDNA A-label, and the whole URI is then encoded again as the `resource` parameter
  describe "fingering the SWICG examples" do
    for {handle, acct} <- [
          {"user1@ตัวอย่าง.example", "acct:user1@xn--72c1a1bt4awk9o.example"},
          {"renée@উদাহরণ.example", "acct:ren%C3%A9e@xn--d5b6ci4b4b3a.example"},
          {"иван@எடுத்துக்காட்டு.example",
           "acct:%D0%B8%D0%B2%D0%B0%D0%BD@xn--4kcoa2bca5aa0vzacf2mdd.example"},
          {"ελπίδα@ఉదాహరణ.example",
           "acct:%CE%B5%CE%BB%CF%80%CE%AF%CE%B4%CE%B1@xn--noc6ci4b4b3a.example"},
          {"小明@მაგალითი.example", "acct:%E5%B0%8F%E6%98%8E@xn--lodafveble.example"},
          {"किरण@example.հայ", "acct:%E0%A4%95%E0%A4%BF%E0%A4%B0%E0%A4%A3@example.xn--y9a3aq"},
          {"ليلى@ምሳሌ.example", "acct:%D9%84%D9%8A%D9%84%D9%89@xn--mxd7a1d.example"},
          {"שרה@example.net", "acct:%D7%A9%D7%A8%D7%94@example.net"},
          {"anne.o'neill+notes@example.مصر", "acct:anne.o'neill+notes@example.xn--wgbh1c"},
          {"민수@example.中国", "acct:%EB%AF%BC%EC%88%98@example.xn--fiqs8s"},
          {"さくら@café.example", "acct:%E3%81%95%E3%81%8F%E3%82%89@xn--caf-dma.example"}
        ] do
      test handle do
        acct = unquote(acct)
        [_, host] = String.split(acct, "@")
        url = "https://#{host}/.well-known/webfinger?" <> URI.encode_query(%{"resource" => acct})
        actor_id = "https://#{host}/users/someone"

        mock(fn
          %{method: :get, url: ^url} ->
            json(%{
              "subject" => acct,
              "links" => [
                %{"rel" => "self", "type" => "application/activity+json", "href" => actor_id}
              ]
            })

          _ ->
            %Tesla.Env{status: 404, body: ""}
        end)

        assert {:ok, %{"id" => ^actor_id}} = WebFinger.finger(unquote(handle))
      end
    end

    test "the lookup URL is exactly the one in the SWICG example" do
      url =
        "https://xn--noc6ci4b4b3a.example/.well-known/webfinger?resource=acct%3A%25CE%25B5%25CE%25BB%25CF%2580%25CE%25AF%25CE%25B4%25CE%25B1%40xn--noc6ci4b4b3a.example"

      mock(fn
        %{method: :get, url: ^url} ->
          json(%{
            "links" => [
              %{
                "rel" => "self",
                "type" => "application/activity+json",
                "href" => "https://xn--noc6ci4b4b3a.example/users/elpida"
              }
            ]
          })

        _ ->
          %Tesla.Env{status: 404, body: ""}
      end)

      assert {:ok, %{"id" => "https://xn--noc6ci4b4b3a.example/users/elpida"}} =
               WebFinger.finger("ελπίδα@ఉదాహరణ.example")
    end
  end

  # hosts MUST be converted to IDNA A-labels before use (W3C SocialCG ActivityPub and WebFinger report, 3.1), both in the URL and in the `acct:` resource
  describe "fingering an internationalized domain" do
    for {handle, url, actor_id} <- [
          {"josé@bücher.local",
           "https://xn--bcher-kva.local/.well-known/webfinger?resource=acct%3Ajos%25C3%25A9%40xn--bcher-kva.local",
           "https://xn--bcher-kva.local/users/jose_u"},
          {"josé@xn--bcher-kva.local",
           "https://xn--bcher-kva.local/.well-known/webfinger?resource=acct%3Ajos%25C3%25A9%40xn--bcher-kva.local",
           "https://xn--bcher-kva.local/users/jose_u"},
          {"你好@你好.local",
           "https://xn--6qq79v.local/.well-known/webfinger?resource=acct%3A%25E4%25BD%25A0%25E5%25A5%25BD%40xn--6qq79v.local",
           "https://xn--6qq79v.local/users/nihao"},
          {"@你好@你好.local",
           "https://xn--6qq79v.local/.well-known/webfinger?resource=acct%3A%25E4%25BD%25A0%25E5%25A5%25BD%40xn--6qq79v.local",
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
