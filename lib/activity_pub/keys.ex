defmodule ActivityPub.Keys do
  @moduledoc """
  Generates RSA keys for HTTP message signatures
  """
  import Untangle

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
    error(pem, "Could not get keys (expected a PEM)")
  end
end
