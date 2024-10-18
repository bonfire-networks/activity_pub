defmodule ActivityPub.Safety.Encryption do
  @moduledoc """
  Provides encryption and decryption functionality using RSA keys managed by ActivityPub.Safety.Keys.

  NOTE: not used at the moment, simply intended as a proof-of-concept
  """
  import Untangle

  alias ActivityPub.Safety.Keys
  alias ActivityPub.Actor

  @doc """
  Encrypts data for a given actor using their public key.

  ## Parameters
    - data: The data to encrypt (binary or string)
    - actor: The Actor struct or AP ID of the recipient

  ## Returns
    - {:ok, encrypted_data} on success
    - {:error, reason} on failure
  """
  def encrypt(data, ap_id) when is_binary(ap_id) do
    with {:ok, public_key} <- Keys.get_public_key_for_ap_id(ap_id) do
      encrypt_with_public_key(data, public_key)
    end
  end

  def encrypt(data, actor) do
    with {:ok, public_key} <- Keys.public_key_from_data(actor) do
      encrypt_with_public_key(data, public_key)
    end
  end

  @doc """
  Decrypts data for a given actor using their private key.

  ## Parameters
    - encrypted_data: The data to decrypt (binary)
    - actor: The Actor struct with private keys

  ## Returns
    - {:ok, decrypted_data} on success
    - {:error, reason} on failure
  """
  def decrypt(encrypted_data, %Actor{local: true, keys: keys} = actor) when not is_nil(keys) do
    with {:ok, private_key, _public_key} <- Keys.keypair_from_pem(keys) do
      decrypt_with_private_key(encrypted_data, private_key)
    end
  end

  def decrypt(encrypted_data, ap_id) when is_binary(ap_id) do
    with {:ok, actor} <- Actor.get_cached(ap_id: ap_id) do
      decrypt(encrypted_data, actor)
    end
  end

  def decrypt(_encrypted_data, %Actor{local: false} = actor) do
    error(actor, "Cannot perform decryption for remote actors")
  end

  def decrypt(_encrypted_data, actor) do
    error(actor, "Could not find a private key to use for decryption")
  end

  # Private functions

  defp encrypt_with_public_key(data, public_key) do
    with {:ok, decoded_key} <- Keys.public_key_decode(public_key) do
      encrypted = :public_key.encrypt_public(data, decoded_key)
      {:ok, encrypted}
    end
  rescue
    e -> error(e)
  end

  defp decrypt_with_private_key(encrypted_data, private_key) do
    decrypted = :public_key.decrypt_private(encrypted_data, private_key)
    {:ok, decrypted}
  rescue
    e in ErlangError ->
      case e do
        %ErlangError{original: {:error, _, msg}} ->
          error(to_string(msg))

        _ ->
          error(e)
      end

    e ->
      error(e)
  end
end
