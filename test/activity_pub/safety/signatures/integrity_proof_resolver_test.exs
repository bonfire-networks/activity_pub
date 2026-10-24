defmodule ActivityPub.Safety.IntegrityProofs.ResolverTest do
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import Tesla.Mock

  alias ActivityPub.Safety.IntegrityProofs.Resolver
  alias ActivityPub.Safety.Multibase
  alias ActivityPub.Test.IntegrityProofFixtures, as: Fixtures

  setup do
    fep = Fixtures.vector(:fep_8b32)
    {:ok, {:ed25519, key}} = Multibase.decode_multikey(fep["publicKeyMultibase"])

    # an unknown URL is a 404, so a test that fetches anything it should not shows up as a failure to find
    mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    # every test has an actor of its own: the actor cache outlives the test's database transaction
    actor_id = "https://server.example/users/alice-#{System.unique_integer([:positive])}"

    %{fep: fep, key: key, actor_id: actor_id, method_id: actor_id <> "#ed25519-key"}
  end

  # a Multikey entry as an actor document lists it under `assertionMethod`
  defp entry(actor_id, fep, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => actor_id <> "#ed25519-key",
        "type" => "Multikey",
        "controller" => actor_id,
        "publicKeyMultibase" => fep["publicKeyMultibase"]
      },
      overrides
    )
  end

  defp remote_actor(actor_id, assertion_method) do
    actor(ap_id: actor_id, data: %{"assertionMethod" => assertion_method})
  end

  describe "the verification method of one of our own actors" do
    # our own signature, such as an activity of ours that a group relays back to us, has to be checkable without asking ourselves over HTTP: the actor we hold has no `assertionMethod` in its data, since it is added when the actor is rendered
    test "is found, with the derived key, without a request" do
      %{username: username} = local_actor()
      {:ok, actor} = ActivityPub.Actor.get_cached(username: username)
      {:ok, {public, _private}} = ActivityPub.Safety.Keys.ed25519_keypair(actor)
      actor_id = actor.data["id"]

      mock(fn %{method: :get} -> flunk("nothing should be asked for") end)

      assert Resolver.resolve(actor_id <> "#ed25519-key") ==
               {:ok, %{controller: actor_id, key: {:ed25519, public}}}

      assert Resolver.resolve(actor_id <> "#ed25519-key", fresh: true) ==
               {:ok, %{controller: actor_id, key: {:ed25519, public}}}
    end

    test "that names a key we do not have is not found", _ctx do
      %{username: username} = local_actor()
      {:ok, actor} = ActivityPub.Actor.get_cached(username: username)
      actor_id = actor.data["id"]

      assert Resolver.resolve(actor_id <> "#some-other-key") ==
               {:error, :verification_method_not_found}
    end
  end

  describe "an https verification method" do
    test "is found in the actor's assertionMethod, and the actor is its controller", ctx do
      remote_actor(ctx.actor_id, [entry(ctx.actor_id, ctx.fep)])

      assert Resolver.resolve(ctx.method_id) ==
               {:ok, %{controller: ctx.actor_id, key: {:ed25519, ctx.key}}}
    end

    test "is found when assertionMethod is a single entry rather than a list", ctx do
      remote_actor(ctx.actor_id, entry(ctx.actor_id, ctx.fep))

      assert {:ok, %{controller: controller}} = Resolver.resolve(ctx.method_id)
      assert controller == ctx.actor_id
    end

    test "is found among other entries, matched by its whole id", ctx do
      other = entry(ctx.actor_id, ctx.fep, %{"id" => ctx.actor_id <> "#another-key"})
      remote_actor(ctx.actor_id, [other, entry(ctx.actor_id, ctx.fep)])

      assert {:ok, %{key: {:ed25519, _}}} = Resolver.resolve(ctx.method_id)
      assert {:ok, %{key: {:ed25519, _}}} = Resolver.resolve(ctx.actor_id <> "#another-key")
    end

    test "is not found when the actor does not list it", ctx do
      remote_actor(ctx.actor_id, [entry(ctx.actor_id, ctx.fep)])

      assert Resolver.resolve(ctx.actor_id <> "#not-listed") ==
               {:error, :verification_method_not_found}
    end

    test "is not found when the actor has no assertionMethod at all", ctx do
      remote_actor(ctx.actor_id, [])
      assert Resolver.resolve(ctx.method_id) == {:error, :verification_method_not_found}
    end

    test "fails when the actor cannot be found", ctx do
      assert Resolver.resolve(ctx.method_id) == {:error, :actor_not_found}
    end

    test "is not a Multikey", ctx do
      remote_actor(ctx.actor_id, [entry(ctx.actor_id, ctx.fep, %{"type" => "CryptographicKey"})])
      assert Resolver.resolve(ctx.method_id) == {:error, :not_multikey}
    end

    test "is a Multikey when its type is a list that includes Multikey", ctx do
      remote_actor(ctx.actor_id, [
        entry(ctx.actor_id, ctx.fep, %{"type" => ["Multikey", "Key"]})
      ])

      assert {:ok, _} = Resolver.resolve(ctx.method_id)
    end

    test "names a controller other than the actor that lists it", ctx do
      remote_actor(ctx.actor_id, [
        entry(ctx.actor_id, ctx.fep, %{"controller" => "https://evil.example/users/bob"})
      ])

      assert Resolver.resolve(ctx.method_id) == {:error, :controller_mismatch}
    end

    test "has been revoked", ctx do
      remote_actor(ctx.actor_id, [
        entry(ctx.actor_id, ctx.fep, %{"revoked" => "2024-01-01T00:00:00Z"})
      ])

      assert Resolver.resolve(ctx.method_id) == {:error, :revoked}
    end

    test "has expired, or has not yet", ctx do
      remote_actor(ctx.actor_id, [
        entry(ctx.actor_id, ctx.fep, %{"expires" => "2020-01-01T00:00:00Z"})
      ])

      assert Resolver.resolve(ctx.method_id) == {:error, :expired_key}

      next_year = DateTime.utc_now() |> DateTime.add(365 * 86_400) |> DateTime.to_iso8601()

      other_id = "https://server.example/users/carol-#{System.unique_integer([:positive])}"
      remote_actor(other_id, [entry(other_id, ctx.fep, %{"expires" => next_year})])

      assert {:ok, _} = Resolver.resolve(other_id <> "#ed25519-key")
    end

    test "holds a key that is not a Multikey we can read", ctx do
      remote_actor(ctx.actor_id, [
        entry(ctx.actor_id, ctx.fep, %{"publicKeyMultibase" => "f6869"})
      ])

      assert Resolver.resolve(ctx.method_id) == {:error, :unsupported_multibase}
    end
  end

  describe "fetching" do
    test "an actor we do not hold is fetched, once, to find it", ctx do
      body = actor_json(ctx.actor_id, [entry(ctx.actor_id, ctx.fep)])

      mock(fn
        %{method: :get, url: url} ->
          assert url == ctx.actor_id

          %Tesla.Env{
            status: 200,
            body: body,
            headers: [{"content-type", "application/activity+json"}]
          }
      end)

      assert {:ok, %{controller: controller}} = Resolver.resolve(ctx.method_id)
      assert controller == ctx.actor_id
    end

    test "a method missing from the actor we hold is looked for once more on the server", ctx do
      remote_actor(ctx.actor_id, [])
      body = actor_json(ctx.actor_id, [entry(ctx.actor_id, ctx.fep)])

      mock(fn %{method: :get} ->
        %Tesla.Env{
          status: 200,
          body: body,
          headers: [{"content-type", "application/activity+json"}]
        }
      end)

      assert {:ok, %{key: {:ed25519, key}}} = Resolver.resolve(ctx.method_id)
      assert key == ctx.key
    end

    test "fresh: true skips what we hold, for a key that has been rotated", ctx do
      {old_key, _} = :crypto.generate_key(:eddsa, :ed25519)
      old = Multibase.encode(<<0xED, 0x01>> <> old_key, :base58btc)

      remote_actor(ctx.actor_id, [entry(ctx.actor_id, ctx.fep, %{"publicKeyMultibase" => old})])

      assert {:ok, %{key: {:ed25519, ^old_key}}} = Resolver.resolve(ctx.method_id)

      body = actor_json(ctx.actor_id, [entry(ctx.actor_id, ctx.fep)])

      mock(fn %{method: :get} ->
        %Tesla.Env{
          status: 200,
          body: body,
          headers: [{"content-type", "application/activity+json"}]
        }
      end)

      assert {:ok, %{key: {:ed25519, new_key}}} = Resolver.resolve(ctx.method_id, fresh: true)
      assert new_key == ctx.key
    end
  end

  describe "a did:key verification method" do
    setup ctx do
      fingerprint = ctx.fep["publicKeyMultibase"]
      mock(fn _ -> raise "a did:key is read from the DID itself, with no request" end)
      %{did_url: "did:key:#{fingerprint}##{fingerprint}"}
    end

    test "is accepted when the owner's actor lists that key", ctx do
      remote_actor(ctx.actor_id, [
        entry(ctx.actor_id, ctx.fep, %{"id" => ctx.actor_id <> "#key-1"})
      ])

      assert Resolver.resolve(ctx.did_url, owner: ctx.actor_id) ==
               {:ok, %{controller: ctx.actor_id, key: {:ed25519, ctx.key}}}
    end

    test "is refused when the owner's actor does not list it", ctx do
      {other, _} = :crypto.generate_key(:eddsa, :ed25519)
      other = Multibase.encode(<<0xED, 0x01>> <> other, :base58btc)

      remote_actor(ctx.actor_id, [
        entry(ctx.actor_id, ctx.fep, %{"publicKeyMultibase" => other})
      ])

      assert Resolver.resolve(ctx.did_url, owner: ctx.actor_id) == {:error, :did_key_not_listed}
    end

    test "is refused when we are not told whose key it should be", ctx do
      remote_actor(ctx.actor_id, [entry(ctx.actor_id, ctx.fep)])
      assert Resolver.resolve(ctx.did_url) == {:error, :did_key_not_listed}
    end

    test "is refused when the actor lists it under another controller", ctx do
      remote_actor(ctx.actor_id, [
        entry(ctx.actor_id, ctx.fep, %{"controller" => "https://evil.example/users/bob"})
      ])

      assert Resolver.resolve(ctx.did_url, owner: ctx.actor_id) == {:error, :did_key_not_listed}
    end
  end

  test "other kinds of verification method are not resolved" do
    for uri <- ["ftp://server.example/alice#key", "did:web:example.com#key", "", nil, 42] do
      assert Resolver.resolve(uri) == {:error, :unsupported_verification_method},
             "#{inspect(uri)} should be unsupported"
    end
  end

  defp actor_json(actor_id, assertion_method) do
    Jason.encode!(%{
      "@context" => ["https://www.w3.org/ns/activitystreams"],
      "id" => actor_id,
      "type" => "Person",
      "preferredUsername" => "alice",
      "inbox" => actor_id <> "/inbox",
      "outbox" => actor_id <> "/outbox",
      "assertionMethod" => assertion_method
    })
  end
end
