defmodule ActivityPub.Safety.PublicKeyPemTest do
  @moduledoc """
  The exact bytes of the `publicKeyPem` we publish on our actors.

  `:public_key.pem_encode/1` terminates with a BLANK line (`-----END PUBLIC KEY-----\\n\\n`). OpenSSL accepts that, which is why it passed every manual check, but strict parsers read the residual newline as the start of another PEM block and reject it at *that* block's pre-encapsulation boundary. Lemmy refused our actor with exactly that error, so it could not verify our signatures and every Follow we sent came back HTTP 400.

  Captured actors from Lemmy, PieFed and Mbin all end with a single newline or none.
  """
  use ActivityPub.DataCase, async: true

  import ActivityPub.Factory

  test "the published PEM has no trailing blank line" do
    actor = local_actor()
    {:ok, actor} = ActivityPub.Actor.get_cached(username: actor.username)

    pem = get_in(actor.data, ["publicKey", "publicKeyPem"])

    assert is_binary(pem)
    assert String.starts_with?(pem, "-----BEGIN PUBLIC KEY-----\n")

    assert String.ends_with?(pem, "-----END PUBLIC KEY-----\n"),
           "expected a single trailing newline, got: #{inspect(String.slice(pem, -34..-1))}"

    refute String.ends_with?(pem, "\n\n"),
           "a trailing blank line is read by strict parsers as a second, malformed PEM block"
  end

  test "the published PEM still parses as a key" do
    actor = local_actor()
    {:ok, actor} = ActivityPub.Actor.get_cached(username: actor.username)

    pem = get_in(actor.data, ["publicKey", "publicKeyPem"])

    # trimming must not have broken the key itself
    assert [entry] = :public_key.pem_decode(pem)
    assert :public_key.pem_entry_decode(entry)
  end
end
