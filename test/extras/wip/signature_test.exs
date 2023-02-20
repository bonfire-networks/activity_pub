defmodule ActivityPub.Safety.SignaturesTest do
  use ActivityPub.DataCase

  import ActivityPub.Factory
  import ExUnit.CaptureLog
  import Tesla.Mock
  import Mock

  alias ActivityPub.Safety.Signatures

  @private_key "-----BEGIN RSA PRIVATE KEY-----\nMIIEpQIBAAKCAQEA48qb4v6kqigZutO9Ot0wkp27GIF2LiVaADgxQORZozZR63jH\nTaoOrS3Xhngbgc8SSOhfXET3omzeCLqaLNfXnZ8OXmuhJfJSU6mPUvmZ9QdT332j\nfN/g3iWGhYMf/M9ftCKh96nvFVO/tMruzS9xx7tkrfJjehdxh/3LlJMMImPtwcD7\nkFXwyt1qZTAU6Si4oQAJxRDQXHp1ttLl3Ob829VM7IKkrVmY8TD+JSlV0jtVJPj6\n1J19ytKTx/7UaucYvb9HIiBpkuiy5n/irDqKLVf5QEdZoNCdojOZlKJmTLqHhzKP\n3E9TxsUjhrf4/EqegNc/j982RvOxeu4i40zMQwIDAQABAoIBAQDH5DXjfh21i7b4\ncXJuw0cqget617CDUhemdakTDs9yH+rHPZd3mbGDWuT0hVVuFe4vuGpmJ8c+61X0\nRvugOlBlavxK8xvYlsqTzAmPgKUPljyNtEzQ+gz0I+3mH2jkin2rL3D+SksZZgKm\nfiYMPIQWB2WUF04gB46DDb2mRVuymGHyBOQjIx3WC0KW2mzfoFUFRlZEF+Nt8Ilw\nT+g/u0aZ1IWoszbsVFOEdghgZET0HEarum0B2Je/ozcPYtwmU10iBANGMKdLqaP/\nj954BPunrUf6gmlnLZKIKklJj0advx0NA+cL79+zeVB3zexRYSA5o9q0WPhiuTwR\n/aedWHnBAoGBAP0sDWBAM1Y4TRAf8ZI9PcztwLyHPzfEIqzbObJJnx1icUMt7BWi\n+/RMOnhrlPGE1kMhOqSxvXYN3u+eSmWTqai2sSH5Hdw2EqnrISSTnwNUPINX7fHH\njEkgmXQ6ixE48SuBZnb4w1EjdB/BA6/sjL+FNhggOc87tizLTkMXmMtTAoGBAOZV\n+wPuAMBDBXmbmxCuDIjoVmgSlgeRunB1SA8RCPAFAiUo3+/zEgzW2Oz8kgI+xVwM\n33XkLKrWG1Orhpp6Hm57MjIc5MG+zF4/YRDpE/KNG9qU1tiz0UD5hOpIU9pP4bR/\ngxgPxZzvbk4h5BfHWLpjlk8UUpgk6uxqfti48c1RAoGBALBOKDZ6HwYRCSGMjUcg\n3NPEUi84JD8qmFc2B7Tv7h2he2ykIz9iFAGpwCIyETQsJKX1Ewi0OlNnD3RhEEAy\nl7jFGQ+mkzPSeCbadmcpYlgIJmf1KN/x7fDTAepeBpCEzfZVE80QKbxsaybd3Dp8\nCfwpwWUFtBxr4c7J+gNhAGe/AoGAPn8ZyqkrPv9wXtyfqFjxQbx4pWhVmNwrkBPi\nZ2Qh3q4dNOPwTvTO8vjghvzIyR8rAZzkjOJKVFgftgYWUZfM5gE7T2mTkBYq8W+U\n8LetF+S9qAM2gDnaDx0kuUTCq7t87DKk6URuQ/SbI0wCzYjjRD99KxvChVGPBHKo\n1DjqMuECgYEAgJGNm7/lJCS2wk81whfy/ttKGsEIkyhPFYQmdGzSYC5aDc2gp1R3\nxtOkYEvdjfaLfDGEa4UX8CHHF+w3t9u8hBtcdhMH6GYb9iv6z0VBTt4A/11HUR49\n3Z7TQ18Iyh3jAUCzFV9IJlLIExq5Y7P4B3ojWFBN607sDCt8BMPbDYs=\n-----END RSA PRIVATE KEY-----"

  @public_key "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAw0P/Tq4gb4G/QVuMGbJo\nC/AfMNcv+m7NfrlOwkVzcU47jgESuYI4UtJayissCdBycHUnfVUd9qol+eznSODz\nCJhfJloqEIC+aSnuEPGA0POtWad6DU0E6/Ho5zQn5WAWUwbRQqowbrsm/GHo2+3v\neR5jGenwA6sYhINg/c3QQbksyV0uJ20Umyx88w8+TJuv53twOfmyDWuYNoQ3y5cc\nHKOZcLHxYOhvwg3PFaGfFHMFiNmF40dTXt9K96r7sbzc44iLD+VphbMPJEjkMuf8\nPGEFOBzy8pm3wJZw2v32RNW2VESwMYyqDzwHXGSq1a73cS7hEnc79gXlELsK04L9\nQQIDAQAB\n-----END PUBLIC KEY-----\n"

  @rsa_public_key {
    :RSAPublicKey,
    24_650_000_183_914_698_290_885_268_529_673_621_967_457_234_469_123_179_408_466_269_598_577_505_928_170_923_974_132_111_403_341_217_239_999_189_084_572_368_839_502_170_501_850_920_051_662_384_964_248_315_257_926_552_945_648_828_895_432_624_227_029_881_278_113_244_073_644_360_744_504_606_177_648_469_825_063_267_913_017_309_199_785_535_546_734_904_379_798_564_556_494_962_268_682_532_371_146_333_972_821_570_577_277_375_020_977_087_539_994_500_097_107_935_618_711_808_260_846_821_077_839_605_098_669_707_417_692_791_905_543_116_911_754_774_323_678_879_466_618_738_207_538_013_885_607_095_203_516_030_057_611_111_308_904_599_045_146_148_350_745_339_208_006_497_478_057_622_336_882_506_112_530_056_970_653_403_292_123_624_453_213_574_011_183_684_739_084_105_206_483_178_943_532_208_537_215_396_831_110_268_758_639_826_369_857,
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

  defp make_fake_signature(key_id), do: "keyId=\"#{key_id}\""

  describe "fetch_public_key/1" do
    test "with fixture" do
      id = "https://mocked.local/users/karen"

      {:ok, {:RSAPublicKey, _, _}} = Signature.fetch_public_key(make_fake_conn(id))
    end

    test "it returns key" do
      expected_result = {:ok, @rsa_public_key}

      user = local_actor(public_key: @public_key)

      assert Signature.fetch_public_key(make_fake_conn(ap_id(user))) == expected_result
    end

    test "it returns {:ok, :nil} when not found user" do
      assert capture_log(fn ->
               assert Signature.fetch_public_key(make_fake_conn("test-ap_id")) ==
                        {:ok, nil}
             end)
    end

    test "it returns error if public key is nil" do
      user = local_actor(public_key: nil)

      assert Signature.fetch_public_key(make_fake_conn(ap_id(user))) == {:error, :error}
    end
  end

  describe "refetch_public_key/2" do
    test "works" do
      id = "https://mocked.local/users/karen"

      {:ok, {:RSAPublicKey, _, _}} = Signature.refetch_public_key(make_fake_conn(id))
    end

    test "it returns error when not found user" do
      assert capture_log(fn ->
               assert {:error, {:error, _}} =
                        Signature.refetch_public_key(make_fake_conn("test-id"))
             end)
    end
  end

  describe "refetch_public_key/1" do
    test "it returns key" do
      ap_id = "https://mocked.local/users/lambadalambda"

      assert Signature.refetch_public_key(make_fake_conn(ap_id)) == {:ok, @rsa_public_key}
    end

    test "it returns error when not found user" do
      assert capture_log(fn ->
               {:error, _} = Signature.refetch_public_key(make_fake_conn("https://test-ap_id"))
             end) =~ "[error] Could not decode user"
    end
  end

  describe "sign/2" do
    test "works" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      _signature =
        Signature.sign(ap_actor, %{
          host: "test.test",
          "content-length": 100
        })
    end

    test "it returns signature headers" do
      user =
        local_actor(%{
          ap_id: "https://mocked.local/users/lambadalambda",
          keys: @private_key
        })

      assert Signature.sign(
               user,
               %{
                 host: "test.test",
                 "content-length": 100
               }
             ) ==
               "keyId=\"https://mocked.local/users/lambadalambda#main-key\",algorithm=\"rsa-sha256\",headers=\"content-length host\",signature=\"sibUOoqsFfTDerquAkyprxzDjmJm6erYc42W5w1IyyxusWngSinq5ILTjaBxFvfarvc7ci1xAi+5gkBwtshRMWm7S+Uqix24Yg5EYafXRun9P25XVnYBEIH4XQ+wlnnzNIXQkU3PU9e6D8aajDZVp3hPJNeYt1gIPOA81bROI8/glzb1SAwQVGRbqUHHHKcwR8keiR/W2h7BwG3pVRy4JgnIZRSW7fQogKedDg02gzRXwUDFDk0pr2p3q6bUWHUXNV8cZIzlMK+v9NlyFbVYBTHctAR26GIAN6Hz0eV0mAQAePHDY1mXppbA8Gpp6hqaMuYfwifcXmcc+QFm4e+n3A==\""
    end

    test "it returns error" do
      user = local_actor(%{ap_id: "https://mocked.local/users/lambadalambda", keys: ""})

      assert Signature.sign(
               user,
               %{host: "test.test", "content-length": 100}
             ) == {:error, []}
    end
  end

  describe "key_id_to_actor_id/1" do
    test "it properly deduces the actor id for misskey" do
      assert Signature.key_id_to_actor_id("https://example.local/users/1234/publickey") ==
               {:ok, "https://example.local/users/1234"}
    end

    test "it properly deduces the actor id for mastodon and pleroma" do
      assert Signature.key_id_to_actor_id("https://example.local/users/1234#main-key") ==
               {:ok, "https://example.local/users/1234"}
    end

    test "it deduces the actor id for gotoSocial" do
      assert Signature.key_id_to_actor_id("https://example.local/users/1234/main-key") ==
               {:ok, "https://example.local/users/1234"}
    end

    test "it calls webfinger for 'acct:' accounts" do
      with_mock(ActivityPub.Web.WebFinger,
        finger: fn _ -> {:ok, %{"ap_id" => "https://gensokyo.2hu/users/raymoo"}} end
      ) do
        assert Signature.key_id_to_actor_id("acct:raymoo@gensokyo.2hu") ==
                 {:ok, "https://gensokyo.2hu/users/raymoo"}
      end
    end
  end

  describe "signed_date" do
    test "it returns formatted current date" do
      with_mock(NaiveDateTime, utc_now: fn -> ~N[2019-08-23 18:11:24.822233] end) do
        assert Signature.signed_date() == "Fri, 23 Aug 2019 18:11:24 GMT"
      end
    end

    test "it returns formatted date" do
      assert Signature.signed_date(~N[2019-08-23 08:11:24.822233]) ==
               "Fri, 23 Aug 2019 08:11:24 GMT"
    end
  end
end
