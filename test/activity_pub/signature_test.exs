defmodule ActivityPub.SignatureTest do
  use ActivityPub.DataCase

  import ActivityPub.Factory
  import ExUnit.CaptureLog
  import Tesla.Mock

  alias ActivityPub.Signature
  alias MoodleNet.Test.Faking

  setup do
    mock(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  defp make_fake_signature(key_id), do: "keyId=\"#{key_id}\""

  defp make_fake_conn(key_id),
    do: %Plug.Conn{req_headers: %{"signature" => make_fake_signature(key_id <> "#main-key")}}

  describe "fetch_public_key/1" do
    test "works" do
      id = "https://kawen.space/users/karen"

      {:ok, {:RSAPublicKey, _, _}} = Signature.fetch_public_key(make_fake_conn(id))
    end

    test "it returns error when not found user" do
      assert capture_log(fn ->
               assert Signature.fetch_public_key(make_fake_conn("test-ap_id")) == {:error, :error}
             end)
    end
  end

  describe "refetch_public_key/2" do
    test "works" do
      id = "https://kawen.space/users/karen"

      {:ok, {:RSAPublicKey, _, _}} = Signature.refetch_public_key(make_fake_conn(id))
    end

    test "it returns error when not found user" do
      assert capture_log(fn ->
               assert Signature.refetch_public_key(make_fake_conn("test-id")) ==
                        {:error, {:error, false}}
             end)
    end
  end

  describe "sign/2" do
    test "works" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_by_username(actor.username)

      _signature =
        Signature.sign(ap_actor, %{
          host: "test.test",
          "content-length": 100
        })
    end
  end
end
