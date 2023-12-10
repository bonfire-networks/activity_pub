defmodule ActivityPub.Safety.SignatureTest do
  use ActivityPub.Web.ConnCase, async: true

  import ActivityPub.Factory
  import ExUnit.CaptureLog
  import Tesla.Mock
  import Mock
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Actor
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Utils
  alias ActivityPub.Safety.Signatures
  alias ActivityPub.Federator.Fetcher

  @private_key "-----BEGIN RSA PRIVATE KEY-----\nMIIEpQIBAAKCAQEA48qb4v6kqigZutO9Ot0wkp27GIF2LiVaADgxQORZozZR63jH\nTaoOrS3Xhngbgc8SSOhfXET3omzeCLqaLNfXnZ8OXmuhJfJSU6mPUvmZ9QdT332j\nfN/g3iWGhYMf/M9ftCKh96nvFVO/tMruzS9xx7tkrfJjehdxh/3LlJMMImPtwcD7\nkFXwyt1qZTAU6Si4oQAJxRDQXHp1ttLl3Ob829VM7IKkrVmY8TD+JSlV0jtVJPj6\n1J19ytKTx/7UaucYvb9HIiBpkuiy5n/irDqKLVf5QEdZoNCdojOZlKJmTLqHhzKP\n3E9TxsUjhrf4/EqegNc/j982RvOxeu4i40zMQwIDAQABAoIBAQDH5DXjfh21i7b4\ncXJuw0cqget617CDUhemdakTDs9yH+rHPZd3mbGDWuT0hVVuFe4vuGpmJ8c+61X0\nRvugOlBlavxK8xvYlsqTzAmPgKUPljyNtEzQ+gz0I+3mH2jkin2rL3D+SksZZgKm\nfiYMPIQWB2WUF04gB46DDb2mRVuymGHyBOQjIx3WC0KW2mzfoFUFRlZEF+Nt8Ilw\nT+g/u0aZ1IWoszbsVFOEdghgZET0HEarum0B2Je/ozcPYtwmU10iBANGMKdLqaP/\nj954BPunrUf6gmlnLZKIKklJj0advx0NA+cL79+zeVB3zexRYSA5o9q0WPhiuTwR\n/aedWHnBAoGBAP0sDWBAM1Y4TRAf8ZI9PcztwLyHPzfEIqzbObJJnx1icUMt7BWi\n+/RMOnhrlPGE1kMhOqSxvXYN3u+eSmWTqai2sSH5Hdw2EqnrISSTnwNUPINX7fHH\njEkgmXQ6ixE48SuBZnb4w1EjdB/BA6/sjL+FNhggOc87tizLTkMXmMtTAoGBAOZV\n+wPuAMBDBXmbmxCuDIjoVmgSlgeRunB1SA8RCPAFAiUo3+/zEgzW2Oz8kgI+xVwM\n33XkLKrWG1Orhpp6Hm57MjIc5MG+zF4/YRDpE/KNG9qU1tiz0UD5hOpIU9pP4bR/\ngxgPxZzvbk4h5BfHWLpjlk8UUpgk6uxqfti48c1RAoGBALBOKDZ6HwYRCSGMjUcg\n3NPEUi84JD8qmFc2B7Tv7h2he2ykIz9iFAGpwCIyETQsJKX1Ewi0OlNnD3RhEEAy\nl7jFGQ+mkzPSeCbadmcpYlgIJmf1KN/x7fDTAepeBpCEzfZVE80QKbxsaybd3Dp8\nCfwpwWUFtBxr4c7J+gNhAGe/AoGAPn8ZyqkrPv9wXtyfqFjxQbx4pWhVmNwrkBPi\nZ2Qh3q4dNOPwTvTO8vjghvzIyR8rAZzkjOJKVFgftgYWUZfM5gE7T2mTkBYq8W+U\n8LetF+S9qAM2gDnaDx0kuUTCq7t87DKk6URuQ/SbI0wCzYjjRD99KxvChVGPBHKo\n1DjqMuECgYEAgJGNm7/lJCS2wk81whfy/ttKGsEIkyhPFYQmdGzSYC5aDc2gp1R3\nxtOkYEvdjfaLfDGEa4UX8CHHF+w3t9u8hBtcdhMH6GYb9iv6z0VBTt4A/11HUR49\n3Z7TQ18Iyh3jAUCzFV9IJlLIExq5Y7P4B3ojWFBN607sDCt8BMPbDYs=\n-----END RSA PRIVATE KEY-----"

  @public_key "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA48qb4v6kqigZutO9Ot0w\nkp27GIF2LiVaADgxQORZozZR63jHTaoOrS3Xhngbgc8SSOhfXET3omzeCLqaLNfX\nnZ8OXmuhJfJSU6mPUvmZ9QdT332jfN/g3iWGhYMf/M9ftCKh96nvFVO/tMruzS9x\nx7tkrfJjehdxh/3LlJMMImPtwcD7kFXwyt1qZTAU6Si4oQAJxRDQXHp1ttLl3Ob8\n29VM7IKkrVmY8TD+JSlV0jtVJPj61J19ytKTx/7UaucYvb9HIiBpkuiy5n/irDqK\nLVf5QEdZoNCdojOZlKJmTLqHhzKP3E9TxsUjhrf4/EqegNc/j982RvOxeu4i40zM\nQwIDAQAB\n-----END PUBLIC KEY-----"

  @rsa_public_key {
    :RSAPublicKey,
    28_756_005_415_572_484_042_763_333_825_843_542_309_845_812_712_410_557_401_080_975_665_944_065_546_687_053_162_744_064_118_733_269_231_397_398_437_337_112_118_822_093_392_471_512_223_279_218_516_015_781_047_498_524_701_011_344_834_660_702_300_339_866_912_903_829_480_780_711_421_965_266_995_321_160_936_070_443_834_148_409_010_341_833_400_730_167_696_056_399_186_720_243_079_891_586_296_037_178_998_225_766_461_225_833_387_132_735_728_367_079_742_073_397_917_419_922_243_432_508_105_117_797_420_565_462_233_617_076_268_056_263_255_047_301_378_690_482_484_074_947_841_896_587_287_731_635_988_553_127_288_143_474_145_525_724_255_965_068_001_976_777_796_779_533_346_344_982_614_532_834_052_163_179_471_788_571_859_959_462_813_779_224_935_806_760_043_776_072_659_926_191_283_296_091_970_506_062_030_984_091_470_929_266_003_011,
    # credo:disable-for-previous-line Credo.Check.Readability.MaxLineLength
    65_537
  }

  setup do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  defp make_fake_signature(key_id), do: "keyId=\"#{key_id}\""

  defp make_fake_conn(key_id),
    do: %Plug.Conn{req_headers: %{"signature" => make_fake_signature(key_id <> "#main-key")}}

  describe "fetch_public_key/1" do
    test "with fixture" do
      id = "https://mocked.local/users/karen"

      {:ok, {:RSAPublicKey, _, _}} = Signatures.fetch_public_key(make_fake_conn(id))
    end

    test "it returns public key" do
      user = local_actor(keys: @private_key)
      info(user, "local_actor which should have keys")

      {:ok, result} = Keys.get_public_key_for_ap_id(ap_id(user))

      assert result =~ @public_key
    end

    test "it decodes public key" do
      user = local_actor(keys: @private_key)
      info(user, "local_actor which should have keys")

      assert Signatures.fetch_public_key(make_fake_conn(ap_id(user))) == {:ok, @rsa_public_key}
    end

    test "it returns {:ok, :nil} when not found user" do
      assert capture_log(fn ->
               assert Signatures.fetch_public_key(make_fake_conn("https://404")) ==
                        {:ok, nil}
             end)
    end

    test "it returns {:ok, nil} if no public key " do
      user = local_actor(keys: "N/A")

      assert Signatures.fetch_public_key(make_fake_conn(ap_id(user))) == {:ok, nil}
    end
  end

  describe "refetch_public_key" do
    test "works" do
      id = "https://mocked.local/users/karen"

      {:ok, {:RSAPublicKey, _, _}} = Signatures.refetch_public_key(make_fake_conn(id))
    end

    test "it returns key" do
      ap_id = "https://mocked.local/users/lambadalambda"

      assert Signatures.refetch_public_key(make_fake_conn(ap_id)) == {:ok, @rsa_public_key}
    end

    test "it returns error when user not found" do
      assert {:error, :not_found} = Signatures.refetch_public_key(make_fake_conn("https://404"))
    end
  end

  describe "sign/2" do
    test "works" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      {:ok, _signature} =
        Keys.sign(ap_actor, %{
          host: "test.test",
          "content-length": 100
        })
    end

    test "it returns correct signature headers" do
      user =
        local_actor(%{
          keys: @private_key
        })
        |> debug("accctor")

      assert Keys.sign(
               user,
               %{
                 host: "test.test",
                 "content-length": 100
               }
             ) ==
               {:ok,
                "keyId=\"#{user.data["id"]}#main-key\",algorithm=\"rsa-sha256\",headers=\"content-length host\",signature=\"sibUOoqsFfTDerquAkyprxzDjmJm6erYc42W5w1IyyxusWngSinq5ILTjaBxFvfarvc7ci1xAi+5gkBwtshRMWm7S+Uqix24Yg5EYafXRun9P25XVnYBEIH4XQ+wlnnzNIXQkU3PU9e6D8aajDZVp3hPJNeYt1gIPOA81bROI8/glzb1SAwQVGRbqUHHHKcwR8keiR/W2h7BwG3pVRy4JgnIZRSW7fQogKedDg02gzRXwUDFDk0pr2p3q6bUWHUXNV8cZIzlMK+v9NlyFbVYBTHctAR26GIAN6Hz0eV0mAQAePHDY1mXppbA8Gpp6hqaMuYfwifcXmcc+QFm4e+n3A==\""}
    end

    test "it returns error when actor has no keys" do
      user = local_actor(%{keys: "N/A"})

      assert {:error, _} =
               Keys.sign(
                 user,
                 %{host: "test.test", "content-length": 100}
               )
    end
  end

  test "without valid signature, it responds with an error, but tries to re-fetch the activity/object (if federation enabled, otherwise accepts nothing)",
       %{conn: conn} do
    create_data = file("fixtures/mastodon/mastodon-post-activity.json") |> Jason.decode!()
    non_create_data = file("fixtures/mastodon/mastodon-announce.json") |> Jason.decode!()

    conn = put_req_header(conn, "content-type", "application/activity+json")

    Oban.Testing.with_testing_mode(:inline, fn ->
      clear_config([:instance, :federating], true)

      assert conn
             |> post("#{Utils.ap_base_url()}/shared_inbox", non_create_data)
             |> json_response(401)

      assert {:ok, _} =
               Object.get_cached(
                 ap_id: "https://mastodon.local/users/admin/statuses/99512778738411822"
               )

      assert json_response(post(conn, "#{Utils.ap_base_url()}/shared_inbox", create_data), 401)

      clear_config([:instance, :federating], false)

      assert conn
             |> post("#{Utils.ap_base_url()}/shared_inbox", create_data)
             |> json_response(403)

      assert conn
             |> post("#{Utils.ap_base_url()}/shared_inbox", non_create_data)
             |> json_response(403)

      clear_config([:instance, :federating], true)
    end)
  end

  describe "key_id_to_actor_id/1" do
    test "it properly deduces the actor id for misskey" do
      assert Keys.key_id_to_actor_id("https://mastodon.local/users/1234/publickey") ==
               {:ok, "https://mastodon.local/users/1234"}
    end

    test "it properly deduces the actor id for mastodon and pleroma" do
      assert Keys.key_id_to_actor_id("https://mastodon.local/users/1234#main-key") ==
               {:ok, "https://mastodon.local/users/1234"}
    end

    test "it deduces the actor id for gotoSocial" do
      assert Keys.key_id_to_actor_id("https://mastodon.local/users/1234/main-key") ==
               {:ok, "https://mastodon.local/users/1234"}
    end

    test "it calls webfinger for 'acct:' accounts" do
      with_mock(ActivityPub.Federator.WebFinger,
        finger: fn _ -> {:ok, %{"ap_id" => "https://gensokyo.2hu/users/raymoo"}} end
      ) do
        assert Keys.key_id_to_actor_id("acct:raymoo@gensokyo.2hu") ==
                 {:ok, "https://gensokyo.2hu/users/raymoo"}
      end
    end
  end

  describe "signed_date" do
    test "it returns formatted current date" do
      with_mock(NaiveDateTime, utc_now: fn _ -> ~N[2019-08-23 18:11:24.822233] end) do
        assert Utils.format_date() == "Fri, 23 Aug 2019 18:11:24 GMT"
      end
    end

    test "it returns formatted date" do
      assert Utils.format_date(~N[2019-08-23 08:11:24.822233]) ==
               "Fri, 23 Aug 2019 08:11:24 GMT"
    end
  end

  describe "signed fetches" do
    setup do: clear_config([:sign_object_fetches])

    test_with_mock "it signs fetches when configured to do so",
                   ActivityPub.Safety.Keys,
                   [:passthrough],
                   [] do
      clear_config([:sign_object_fetches], true)

      Fetcher.fetch_object_from_id("https://mastodon.local/@admin/99512778738411822")

      assert_called(ActivityPub.Safety.Keys.sign(:_, :_))
    end

    test_with_mock "it doesn't sign fetches when not configured to do so",
                   ActivityPub.Safety.Keys,
                   [:passthrough],
                   [] do
      clear_config([:sign_object_fetches], false)

      Fetcher.fetch_object_from_id("https://mastodon.local/@admin/99512778738411822")

      assert_not_called(ActivityPub.Safety.Keys.sign(:_, :_))
    end
  end
end
