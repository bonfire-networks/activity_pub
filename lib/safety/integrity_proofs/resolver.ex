# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Safety.IntegrityProofs.Resolver do
  @moduledoc """
  Turns a proof's `verificationMethod` into a public key and the actor who controls it.

  The key is read from the actor document, in `assertionMethod` (FEP-521a), as a Multikey (https://www.w3.org/TR/cid/#Multikey). That is what makes it a *reciprocal claim* in FEP-fe34's terms: the proof names the key, and the actor's own server says the key is theirs. A key that only the proof vouches for proves nothing.

    * an `https:` method such as `https://server.example/users/alice#ed25519-key` is looked up in the actor at the address before the `#`
    * a `did:key:` method carries its key in the DID itself, so nothing is fetched for the key, but it is only accepted when the owner's actor lists that same key. Without that, anyone could mint a key and sign as anybody.

  What this does not check: that the controller is the owner of the signed document, and that the key's origin is the document's. Those belong to `ActivityPub.Safety.IntegrityProofs.verify/1`, which knows the document.
  """

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Safety.Multibase
  alias ActivityPub.Actor

  @type resolved :: %{controller: String.t(), key: {:ed25519 | :mldsa44, binary()}}

  @doc """
  Resolves a verification method.

  Options:

    * `:fresh`: fetch the actor from its server, skipping what we hold. For a key that has been rotated, which a failed signature is the only sign of.
    * `:owner`: the actor id the signed document belongs to. Needed for a `did:key:` method, which says nothing about who it belongs to.

  A method missing from an actor we already hold is looked for once more on the server before it counts as missing.
  """
  @spec resolve(term(), keyword()) :: {:ok, resolved()} | {:error, atom()}
  def resolve(verification_method, opts \\ [])

  def resolve("did:key:" <> _ = did_url, opts), do: resolve_did_key(did_url, opts)

  def resolve("http" <> _ = uri, opts) do
    if String.starts_with?(uri, ["https://", "http://"]),
      do: resolve_http(uri, opts),
      else: unsupported()
  end

  def resolve(_other, _opts), do: unsupported()

  defp unsupported, do: {:error, :unsupported_verification_method}

  # --- https ---

  defp resolve_http(uri, opts) do
    with {:ok, actor_id} <- actor_id(uri),
         {:ok, data, fetched?} <- load_actor(actor_id, opts[:fresh]),
         {:ok, entry} <- find_method(data, uri, actor_id, fetched?) do
      validate(entry, actor_id)
    end
  end

  defp actor_id(uri) do
    case Keys.key_id_to_actor_id(uri) do
      {:ok, actor_id} -> {:ok, actor_id}
      _ -> {:error, :actor_not_found}
    end
  end

  # the actor's data, and whether it came straight from the server just now
  defp load_actor(actor_id, fresh) do
    case Actor.get_cached(ap_id: actor_id) do
      {:ok, %Actor{local: true} = actor} ->
        # one of ours: the data we hold has no `assertionMethod` until the actor is rendered, which `add_public_key/1` does, so our own signatures can be checked without asking ourselves over HTTP. There is nothing fresher to ask for either

        {:ok, Keys.add_public_key(actor).data, true}

      _ when fresh == true ->
        fetch_actor(actor_id)

      {:ok, %{data: %{} = data}} ->
        {:ok, data, false}

      _ ->
        fetch_actor(actor_id)
    end
  end

  defp fetch_actor(actor_id) do
    case Fetcher.fetch_fresh_object_from_id(actor_id) do
      {:ok, %{data: %{} = data}} -> {:ok, data, true}
      _ -> {:error, :actor_not_found}
    end
  end

  # not in the actor we hold: it may have been added since, so ask the server once
  defp find_method(data, uri, actor_id, fetched?) do
    case Enum.find(methods(data), &(&1["id"] == uri)) do
      nil when fetched? ->
        {:error, :verification_method_not_found}

      nil ->
        with {:ok, data, true} <- fetch_actor(actor_id) do
          find_method(data, uri, actor_id, true)
        else
          _ -> {:error, :verification_method_not_found}
        end

      entry ->
        {:ok, entry}
    end
  end

  defp methods(data) do
    data["assertionMethod"]
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  # --- did:key ---

  defp resolve_did_key(did_url, opts) do
    owner = opts[:owner]
    fingerprint = did_url |> String.replace_prefix("did:key:", "") |> String.split("#") |> hd()

    with true <- is_binary(owner) or {:error, :did_key_not_listed},
         {:ok, _key} <- Multibase.decode_multikey(fingerprint),
         {:ok, data, _fetched?} <- load_actor(owner, opts[:fresh]),
         %{} = entry <-
           Enum.find(
             methods(data),
             &(&1["publicKeyMultibase"] == fingerprint and &1["controller"] == owner)
           ) || {:error, :did_key_not_listed} do
      validate(entry, owner)
    end
  end

  # --- the entry itself ---

  defp validate(entry, controller) do
    with :ok <- check(multikey?(entry["type"]), :not_multikey),
         :ok <- check(entry["controller"] == controller, :controller_mismatch),
         :ok <- check(is_nil(entry["revoked"]), :revoked),
         :ok <- not_expired(entry["expires"]),
         {:ok, key} <- Multibase.decode_multikey(entry["publicKeyMultibase"]) do
      {:ok, %{controller: controller, key: key}}
    end
  end

  defp multikey?(type), do: "Multikey" in List.wrap(type)

  defp check(true, _error), do: :ok
  defp check(false, error), do: {:error, error}

  defp not_expired(nil), do: :ok

  defp not_expired(expires) when is_binary(expires) do
    case DateTime.from_iso8601(expires) do
      {:ok, at, _offset} ->
        check(DateTime.compare(at, DateTime.utc_now()) == :gt, :expired_key)

      _ ->
        {:error, :invalid_expires}
    end
  end

  defp not_expired(_), do: {:error, :invalid_expires}
end
