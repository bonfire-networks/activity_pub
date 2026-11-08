defmodule ActivityPub.Web.Plugs.SignedFetchUnvalidatedTest do
  @moduledoc """
  A signed GET that would be served unsigned anyway (the service actor, and public actors when only non-public things need a signature) is not validated, so the signer's key is not fetched.

  Validating it can start a loop: our fetcher signs every GET as the service actor, so when two servers have each lost the other's key, fetching one's service actor makes it fetch the asker's service actor (signed), which makes the asker fetch back, without end.

  Signatures here are real headers that don't verify, and the signer is not cached, so validating one means fetching the signer's actor, which the tests watch for.
  """
  use ActivityPub.Web.ConnCase, async: false

  import ActivityPub.Factory
  import Tesla.Mock

  alias ActivityPub.Test.HttpRequestMock

  # a remote actor the request mock knows, and that is not cached
  @signer "https://mastodon.local/users/admin"

  setup do
    test = self()

    mock_global(fn env ->
      if env.method == :get and env.url == @signer, do: send(test, {:signer_requested, env.url})
      HttpRequestMock.request(env)
    end)

    clear_config([:reject_unsigned], true)
    :ok
  end

  defp signed_fetch(path) do
    build_conn()
    |> put_req_header("accept", "application/activity+json")
    |> put_req_header(
      "signature",
      ~s|keyId="#{@signer}#main-key",algorithm="rsa-sha256",headers="(request-target) date",signature="aGVsbG8="|
    )
    |> get(path)
  end

  defp path_of(ap_id), do: URI.parse(ap_id).path

  test "a signed GET of the service actor is served without fetching the signer's key" do
    conn = signed_fetch(path_of(ActivityPub.Utils.service_actor!().ap_id))

    assert conn.status == 200
    refute_received {:signer_requested, _}
  end

  test "a signed GET of a public person is served without fetching the signer's key, when only non-public things need a signature" do
    actor = local_actor()
    conn = signed_fetch(path_of(actor.actor.ap_id))

    assert conn.status == 200
    refute_received {:signer_requested, _}
  end

  test "control: a signed GET of an object is still validated, so the signer's key is fetched" do
    object = insert(:note)
    uuid = object.data["id"] |> String.split("/") |> List.last()

    signed_fetch("/pub/objects/#{uuid}")

    assert_received {:signer_requested, @signer}
  end
end
