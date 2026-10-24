# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Safety.IntegrityProofs.Cryptosuites do
  @moduledoc """
  The signature half of the JCS Data Integrity cryptosuites: given the 64 bytes `ActivityPub.Safety.IntegrityProofs.Proof.hash_data/2` produced, check a signature with a public key.

    * `eddsa-jcs-2022`: Ed25519, 64-byte signature, 32-byte key (https://www.w3.org/TR/vc-di-eddsa/)
    * `mldsa44-jcs-2024`: ML-DSA-44, 2420-byte signature, 1312-byte key (https://www.w3.org/TR/vc-di-quantum-resistant/)

  Both are JCS with SHA-256, so they differ only here. The RDF-canonicalisation suites (`eddsa-rdfc-2022` and the like) need a JSON-LD processor, which is the attack surface this work avoids, and ECDSA is not what the fediverse uses, so those are `:unsupported_cryptosuite`.

  ML-DSA exists only when the OpenSSL that OTP was built against has it, so `supported/0` is decided at run time. Where it is missing, an ML-DSA proof is treated as one we cannot check, like an unknown suite, and the delivery goes on to other authentication.

  This module knows nothing about ActivityPub, so it can move into a package of its own.
  """

  @suites %{
    "eddsa-jcs-2022" => %{key_type: :ed25519, key_size: 32, signature_size: 64},
    "mldsa44-jcs-2024" => %{key_type: :mldsa44, key_size: 1312, signature_size: 2420}
  }

  # what Proof.hash_data/2 returns: two SHA-256 hashes, joined
  @hash_size 64

  @type key :: {:ed25519 | :mldsa44, binary()}

  @doc "The cryptosuites that can be checked on this machine."
  @spec supported() :: [String.t()]
  def supported do
    if mldsa44_available?(),
      do: ["eddsa-jcs-2022", "mldsa44-jcs-2024"],
      else: ["eddsa-jcs-2022"]
  end

  defp mldsa44_available?, do: :mldsa44 in :crypto.supports(:public_keys)

  @doc """
  Checks `signature` over `hash_data` with the public key, for the proof's `cryptosuite`.

  The key is what `ActivityPub.Safety.Multibase.decode_multikey/1` returns. Returns `:ok`, or an error:

    * `:unsupported_cryptosuite`: not one of `supported/0` (the `supported:` option replaces that list, for tests)
    * `:key_type_mismatch`: an Ed25519 key named by an ML-DSA proof, or the other way round
    * `:bad_key`, `:bad_key_length`, `:bad_hash`, `:bad_signature_size`: wrong shape, refused before any cryptography runs
    * `:bad_signature`: the shapes are right and the signature does not verify
  """
  @spec verify(term(), binary(), binary(), key(), keyword()) :: :ok | {:error, atom()}
  def verify(cryptosuite, hash_data, signature, key, opts \\ [])

  def verify(cryptosuite, hash_data, signature, {key_type, public_key}, opts)
      when is_binary(cryptosuite) and is_binary(hash_data) and is_binary(signature) and
             is_binary(public_key) do
    supported = Keyword.get_lazy(opts, :supported, &supported/0)

    with {:ok, suite} <- suite(cryptosuite, supported),
         :ok <- check(suite.key_type == key_type, :key_type_mismatch),
         :ok <- check(byte_size(public_key) == suite.key_size, :bad_key_length),
         :ok <- check(byte_size(hash_data) == @hash_size, :bad_hash),
         :ok <- check(byte_size(signature) == suite.signature_size, :bad_signature_size) do
      if do_verify(suite.key_type, hash_data, signature, public_key),
        do: :ok,
        else: {:error, :bad_signature}
    end
  end

  # a suite we know, with something wrong about the rest of the arguments
  def verify(cryptosuite, _hash_data, _signature, _key, _opts) when is_binary(cryptosuite),
    do: if(Map.has_key?(@suites, cryptosuite), do: {:error, :bad_key}, else: unsupported())

  def verify(_cryptosuite, _hash_data, _signature, _key, _opts), do: unsupported()

  defp unsupported, do: {:error, :unsupported_cryptosuite}

  defp suite(cryptosuite, supported) do
    if cryptosuite in supported and Map.has_key?(@suites, cryptosuite),
      do: {:ok, @suites[cryptosuite]},
      else: unsupported()
  end

  defp check(true, _error), do: :ok
  defp check(false, error), do: {:error, error}

  defp do_verify(:ed25519, hash_data, signature, public_key),
    do: :crypto.verify(:eddsa, :none, hash_data, signature, [public_key, :ed25519])

  defp do_verify(:mldsa44, hash_data, signature, public_key),
    do: :crypto.verify(:mldsa44, :none, hash_data, signature, public_key)
end
