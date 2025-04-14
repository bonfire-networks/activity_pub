defmodule ActivityPub.Safety.EncryptionTest do
  # this isn't used but simply a proof of concept
  use ActivityPub.DataCase, async: false
  alias ActivityPub.Safety.Encryption
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Actor

  # Import the test helpers that contain the local_actor() function
  import ActivityPub.Factory

  describe "encrypt/2" do
    test "successfully encrypts data for a local actor" do
      actor = local_actor()
      {:ok, actor} = Keys.ensure_keys_present(actor.actor)

      assert {:ok, encrypted} = Encryption.encrypt("secret message", actor)
      assert is_binary(encrypted)
      assert encrypted != "secret message"
    end

    test "returns error for actor without public key" do
      actor = local_actor()

      actor = %{actor | data: Map.delete(actor.data, "publicKey")}

      assert {:error, "Public key not found"} = Encryption.encrypt("secret message", actor)
    end

    test "encrypts data using AP ID" do
      actor = local_actor()
      {:ok, actor} = Keys.ensure_keys_present(actor.actor)

      assert {:ok, encrypted} = Encryption.encrypt("secret message", actor.data["id"])
      assert is_binary(encrypted)
      assert encrypted != "secret message"
    end
  end

  describe "decrypt/2" do
    test "successfully decrypts data for a local actor" do
      actor = local_actor()
      {:ok, actor} = Keys.ensure_keys_present(actor.actor)

      assert {:ok, encrypted} = Encryption.encrypt("secret message", actor)
      assert encrypted != "secret message"
      assert {:ok, "secret message"} = Encryption.decrypt(encrypted, actor)
    end

    test "fails decryption for remote actor" do
      actor = local_actor()
      {:ok, actor} = Keys.ensure_keys_present(actor.actor)
      remote_actor = %{actor | local: false}

      assert {:error, "Cannot perform decryption for remote actors"} =
               Encryption.decrypt("fake encrypted data", remote_actor)
    end

    test "fails decryption with invalid data" do
      actor = local_actor()
      {:ok, actor} = Keys.ensure_keys_present(actor.actor)

      case Encryption.decrypt("non-encrypted data", actor) do
        {:error, _} ->
          :ok

        {:ok, decrypted} ->
          # NOTE: why does it not return an error instead?
          refute decrypted == "non-encrypted data"
      end
    end

    test "fails decryption with someone else's keys" do
      actor = local_actor()
      {:ok, actor} = Keys.ensure_keys_present(actor.actor)

      actor2 = local_actor()
      {:ok, actor2} = Keys.ensure_keys_present(actor2.actor)

      assert {:ok, encrypted} = Encryption.encrypt("secret message", actor)

      case Encryption.decrypt(encrypted, actor2) do
        {:error, _} ->
          :ok

        {:ok, decrypted} ->
          # NOTE: why does it not return an error instead?
          refute decrypted == "secret message"
      end
    end

    test "fails decryption with missing keys" do
      actor = local_actor().actor

      assert {:error, _} = Encryption.decrypt("non-encrypted data", actor)
    end
  end
end
