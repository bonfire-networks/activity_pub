defmodule ActivityPub.Safety.IntegrityProofsReceiverTest do
  @moduledoc """
  A document that arrives with no HTTP signature, but with a FEP-8b32 proof, is accepted when the proof verifies: the proof is what tells us who sent it. Anything wrong with the proof leaves the document where it was before proofs, in the cascade of the other ways to authenticate it. The origin is made unreachable here (every GET is a 404), so only a proof can get a document through.
  """
  use ActivityPub.Web.ConnCase

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers
  import Plug.Conn
  import Phoenix.ConnTest
  import Tesla.Mock

  alias ActivityPub.Utils

  setup do
    mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)
    :ok
  end

  # an actor on a host of its own, listing a key of its own, and a public Create of a Note by it
  defp new_signer(host \\ "proofs-#{System.unique_integer([:positive])}.example", name \\ "alice") do
    actor_id = "https://#{host}/users/#{name}"
    key = new_key(:ed25519)
    actor(ap_id: actor_id, data: %{"assertionMethod" => [multikey(actor_id, key)]})
    %{id: actor_id, key: key, host: host}
  end

  defp object_id(document), do: document["object"]["id"]

  # POSTs a document to the shared inbox the way a remote server does, with no HTTP signature unless asked, and runs the job it queues at once
  defp deliver(conn, document, headers \\ []) do
    conn = put_req_header(conn, "content-type", "application/activity+json")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    Oban.Testing.with_testing_mode(:inline, fn ->
      clear_config([:instance, :federating], true)
      post(conn, "#{Utils.ap_base_url()}/shared_inbox", document) |> json_response(200)
    end)
  end

  defp accepted?(document),
    do: match?({:ok, _}, ActivityPub.Object.get_cached(ap_id: object_id(document)))

  test "a valid proof is enough, with nothing else to authenticate the document", %{conn: conn} do
    signer = new_signer()
    document = signer.id |> create_note("<p>signed, nothing else</p>") |> sign(signer.key)

    deliver(conn, document)

    assert accepted?(document), "the proof says who sent it, so the Note should be stored"
  end

  test "a Create signed on its object only is enough", %{conn: conn} do
    signer = new_signer()

    document =
      signer.id
      |> create_note("<p>only the object is signed</p>")
      |> Map.update!("object", &sign(&1, signer.key))

    deliver(conn, document)

    assert accepted?(document)
  end

  test "a Create whose object was changed after it was signed is not accepted", %{conn: conn} do
    signer = new_signer()

    document =
      signer.id
      |> create_note("<p>as signed</p>")
      |> Map.update!("object", &sign(&1, signer.key))
      |> put_in(["object", "content"], "<p>as changed on the way</p>")

    deliver(conn, document)

    refute accepted?(document)
  end

  test "a proof made the way Mitra makes them, with no @context of its own, is enough too", %{
    conn: conn
  } do
    signer = new_signer()
    document = signer.id |> create_note() |> sign(signer.key, context_style: :mitra)

    deliver(conn, document)

    assert accepted?(document)
  end

  test "a document changed after it was signed is not accepted", %{conn: conn} do
    signer = new_signer()

    document =
      signer.id
      |> create_note("<p>as signed</p>")
      |> sign(signer.key)
      |> put_in(["object", "content"], "<p>as changed on the way</p>")

    deliver(conn, document)

    refute accepted?(document)
  end

  test "a valid proof by one actor does not make a document by another acceptable", %{conn: conn} do
    alice = new_signer("shared-#{System.unique_integer([:positive])}.example", "alice")
    bob = new_signer(alice.host, "bob")

    document =
      bob.id
      |> create_note("<p>claims to be bob's</p>")
      |> sign(alice.key, verification_method: alice.id <> "#ed25519-key")

    deliver(conn, document)

    refute accepted?(document)
  end

  test "a proof that does not verify is not a reason to refuse what could be authenticated otherwise",
       %{conn: conn} do
    signer = new_signer()

    # the proof is broken, but the origin serves the object, as it would for a refetch
    document =
      signer.id
      |> create_note("<p>served by its origin</p>")
      |> sign(signer.key)
      |> put_in(["proof", "proofValue"], "z2NEpo7TZRRrLZSi2U")

    note = document["object"]
    activity_id = document["id"]

    mock(fn
      %{method: :get, url: ^activity_id} ->
        %Tesla.Env{
          status: 200,
          body: document |> Map.delete("proof") |> Jason.encode!(),
          headers: [{"content-type", "application/activity+json"}]
        }

      %{method: :get, url: url} ->
        if url == note["id"],
          do: %Tesla.Env{
            status: 200,
            body: Jason.encode!(note),
            headers: [{"content-type", "application/activity+json"}]
          },
          else: %Tesla.Env{status: 404, body: ""}
    end)

    deliver(conn, document)

    assert accepted?(document),
           "the cascade after a failed proof is the one there was before proofs"
  end

  test "a failed HTTP signature does not stop a valid proof", %{conn: conn} do
    signer = new_signer()
    document = signer.id |> create_note() |> sign(signer.key)

    bogus =
      ~s[keyId="#{signer.id}#main-key",algorithm="rsa-sha256",headers="(request-target) host date digest",signature="AAAA"]

    deliver(conn, document, [{"signature", bogus}])

    assert accepted?(document)
  end

  test "a proof together with a legacy LD signature that is wrong still verifies, since the LD signature is left out of what the proof covers",
       %{conn: conn} do
    signer = new_signer()

    document =
      signer.id
      |> create_note()
      |> sign(signer.key)
      |> Map.put("signature", %{
        "type" => "RsaSignature2017",
        "creator" => signer.id <> "#main-key",
        "created" => "2026-10-23T12:00:00Z",
        "signatureValue" => "c2lnbmF0dXJl"
      })

    deliver(conn, document)

    assert accepted?(document)
  end
end
