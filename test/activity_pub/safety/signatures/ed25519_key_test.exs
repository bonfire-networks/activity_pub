defmodule ActivityPub.Safety.Ed25519KeyTest do
  @moduledoc """
  A local actor's Ed25519 key (for FEP-8b32 integrity proofs) is derived from its RSA key, not stored: HKDF-SHA256 over the DER of the RSA private key, with no salt and a label, gives a 32-byte seed. So there is no migration, it is the same every time, and it changes if the RSA key does.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Safety.HKDF
  alias ActivityPub.Safety.Keys

  # the label that separates this key from anything else made from the same RSA key; `v1` leaves room to derive another later
  @label "bonfire ed25519 assertion key v1"

  defp new_pem do
    {:ok, pem} = Keys.generate_rsa_pem()
    pem
  end

  defp actor_with(pem), do: %{keys: pem, local: true}

  # the same key, with its base64 body cut at another width
  defp rewrapped(pem, width) do
    lines = String.split(pem, "\n", trim: true)
    [header | rest] = lines
    {body, [footer]} = Enum.split(rest, -1)

    wrapped =
      body
      |> Enum.join()
      |> String.graphemes()
      |> Enum.chunk_every(width)
      |> Enum.map(&Enum.join/1)

    Enum.join([header] ++ wrapped ++ [footer], "\n") <> "\n"
  end

  test "gives a 32-byte public key and a 32-byte private key" do
    assert {:ok, {public, private}} = Keys.ed25519_keypair(actor_with(new_pem()))

    assert byte_size(public) == 32
    assert byte_size(private) == 32
  end

  test "is the same every time for the same RSA key" do
    pem = new_pem()

    assert Keys.ed25519_keypair(actor_with(pem)) == Keys.ed25519_keypair(actor_with(pem))
  end

  test "is a different key for a different RSA key" do
    {:ok, {one, _}} = Keys.ed25519_keypair(actor_with(new_pem()))
    {:ok, {two, _}} = Keys.ed25519_keypair(actor_with(new_pem()))

    refute one == two
  end

  test "does not depend on how the PEM is wrapped" do
    pem = new_pem()

    for width <- [40, 64, 76] do
      assert Keys.ed25519_keypair(actor_with(rewrapped(pem, width))) ==
               Keys.ed25519_keypair(actor_with(pem)),
             "the PEM at #{width} columns gave another key"
    end
  end

  test "is HKDF-SHA256 over the DER of the RSA private key, with no salt and the label" do
    pem = new_pem()
    {:ok, private_key, _public_key} = Keys.keypair_from_pem(pem)

    # the documented derivation, written out
    seed =
      HKDF.derive(:sha256, :public_key.der_encode(:RSAPrivateKey, private_key), 32, "", @label)

    {public, private} = :crypto.generate_key(:eddsa, :ed25519, seed)

    assert Keys.ed25519_keypair(actor_with(pem)) == {:ok, {public, private}}
  end

  test "signs, and what it signed verifies" do
    {:ok, {public, private}} = Keys.ed25519_keypair(actor_with(new_pem()))
    message = "what is signed"

    signature = :crypto.sign(:eddsa, :none, message, [private, :ed25519])

    assert :crypto.verify(:eddsa, :none, message, signature, [public, :ed25519])
    refute :crypto.verify(:eddsa, :none, message <> "!", signature, [public, :ed25519])
  end

  test "does not depend on the actor's id, so a move to another domain keeps the key" do
    pem = new_pem()

    one = Map.put(actor_with(pem), :ap_id, "https://one.example/actors/a")
    two = Map.put(actor_with(pem), :ap_id, "https://two.example/actors/b")

    assert Keys.ed25519_keypair(one) == Keys.ed25519_keypair(two)
  end

  describe "for a local actor" do
    test "that has no RSA key yet, makes one first, and keeps the same key from then on" do
      %{username: username} = local_actor()
      {:ok, actor} = ActivityPub.Actor.get_cached(username: username)

      assert {:ok, {public, _private}} = Keys.ed25519_keypair(actor)

      {:ok, actor} = ActivityPub.Actor.get_cached(username: username)
      assert is_binary(actor.keys)
      assert {:ok, {^public, _}} = Keys.ed25519_keypair(actor)
    end
  end

  describe "for a local actor struct that was loaded before the actor had a key" do
    # the struct stays keyless after the key is made and saved, so a caller holding it asks again: that must give the key that was saved, not make another and replace it
    setup do
      %{username: username} = local_actor()
      {:ok, stale} = ActivityPub.Actor.get_cached(username: username)
      assert is_nil(stale.keys), "the actor has no key yet, or this test shows nothing"

      %{stale: stale, username: username}
    end

    test "asking for the RSA key twice gives the same key", %{stale: stale} do
      assert {:ok, first} = Keys.ensure_keys_present(stale)
      assert {:ok, second} = Keys.ensure_keys_present(stale)

      assert is_binary(first.keys)
      assert second.keys == first.keys
    end

    test "the key that was saved is the one that stays", %{stale: stale, username: username} do
      {:ok, first} = Keys.ensure_keys_present(stale)
      {:ok, _again} = Keys.ensure_keys_present(stale)

      {:ok, stored} = ActivityPub.Actor.get_cached(username: username)
      assert stored.keys == first.keys
    end

    test "asking for the Ed25519 key twice gives the same key", %{stale: stale} do
      assert {:ok, first} = Keys.ed25519_keypair(stale)
      assert {:ok, second} = Keys.ed25519_keypair(stale)

      assert first == second
    end
  end

  describe "for an actor that is not ours" do
    test "there is no key to derive" do
      assert {:error, _} = Keys.ed25519_keypair(%{keys: nil, local: false})
      assert {:error, _} = Keys.ed25519_keypair(%{keys: new_pem(), local: false})
    end
  end
end
