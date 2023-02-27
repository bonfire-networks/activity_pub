defmodule ActivityPub.Safety.Keys do
  @moduledoc """
  Generates RSA keys for HTTP message signatures
  """
  import Untangle
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Adapter

  @doc false
  def add_public_key(%{data: _} = actor) do
    with {:ok, actor} <- ensure_keys_present(actor),
         {:ok, _, public_key} <- keys_from_pem(actor.keys) do
      public_key = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)
      public_key = :public_key.pem_encode([public_key])

      Map.put(
        actor,
        :data,
        Map.merge(
          actor.data,
          %{
            "publicKey" => %{
              "id" => "#{actor.data["id"]}#main-key",
              "owner" => actor.data["id"],
              "publicKeyPem" => public_key
            }
          }
        )
      )
    else
      e ->
        error(e, "Could not add public key")
        actor
    end
  end

  @doc """
  Checks if an actor struct has a non-nil keys field and generates a PEM if it doesn't.
  """
  def ensure_keys_present(actor) do
    if actor.keys do
      {:ok, actor}
    else
      with {:ok, pem} <- generate_rsa_pem(),
           {:ok, actor} <- Adapter.update_local_actor(actor, %{keys: pem}),
           {:ok, actor} <- Actor.set_cache(actor) do
        {:ok, actor}
      else
        e -> error(e, "Could not generate or save keys")
      end
    end
  end

  def generate_rsa_pem() do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    pem = :public_key.pem_encode([entry]) |> String.trim_trailing()
    {:ok, pem}
  end

  def keys_from_pem(pem) when is_binary(pem) do
    with [private_key_code] <- :public_key.pem_decode(pem),
         private_key <- :public_key.pem_entry_decode(private_key_code),
         {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} <-
           private_key do
      {:ok, private_key, {:RSAPublicKey, modulus, exponent}}
    else
      error -> error(error)
    end
  end

  def keys_from_pem(pem) do
    error(pem, "Could not get keys for actor (expected a PEM)")
  end
end
