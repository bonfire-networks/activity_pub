defmodule ActivityPub.Safety.FirstKeyTest do
  @moduledoc """
  A local actor has no RSA key until one is needed: the first time its public key is asked for (a publish, rendering its actor document) one is made and saved. The actor handed back has it, so the publish that asked can sign. Seen in the logs of a dev instance as "Could not get keys for actor (expected a PEM): nil" from `add_public_key/2` during a publish job.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Safety.Keys

  test "a local actor with no key yet gets one, and publishes it" do
    %{username: username} = local_actor()
    {:ok, actor} = ActivityPub.Actor.get_cached(username: username)

    assert is_nil(actor.keys), "control: the actor has no key yet"

    published = Keys.add_public_key(actor)

    assert %{"publicKey" => %{"publicKeyPem" => pem}} = published.data
    assert pem =~ "BEGIN PUBLIC KEY"
    assert is_binary(published.keys), "the actor handed back holds the key it was just given"
  end

  test "a group with no key yet gets one too" do
    creator = Bonfire.Me.Fake.fake_user!()
    group = Bonfire.Classify.Simulate.fake_group!(creator)
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)

    published = Keys.add_public_key(actor)

    assert %{"publicKey" => %{"publicKeyPem" => pem}} = published.data
    assert pem =~ "BEGIN PUBLIC KEY"
  end

  test "asking again finds the key that was made, and makes no other" do
    %{username: username} = local_actor()
    {:ok, actor} = ActivityPub.Actor.get_cached(username: username)

    first = Keys.add_public_key(actor)
    {:ok, stale} = ActivityPub.Actor.get_cached(username: username)
    # a struct from before the key was made
    second = Keys.add_public_key(%{stale | keys: nil})

    assert second.data["publicKey"]["publicKeyPem"] == first.data["publicKey"]["publicKeyPem"]
  end
end
