defmodule ActivityPub.Safety.Keys do
  @moduledoc """
  Handles RSA keys for Actors & helpers for HTTP signatures
  """

  import Untangle
  use Arrows

  alias ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Utils
  alias ActivityPub.Safety.Keys
  # alias ActivityPub.Safety.HTTP.Signatures
  # alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter

  alias ActivityPub.Safety.HKDF
  alias ActivityPub.Safety.Multibase

  @known_suffixes ["/publickey", "/main-key"]

  # separates the Ed25519 key from anything else made from the same RSA key; `v1` leaves room to derive another later
  @ed25519_label "bonfire ed25519 assertion key v1"

  @doc """
  Get the public key for given actor AP ID.
  """
  def get_public_key_for_ap_id(ap_id) do
    with {:ok, actor} <- Actor.get_cached(ap_id: ap_id),
         {:ok, public_key} <- public_key_from_data(actor) do
      {:ok, public_key}
    else
      e ->
        error(e)
    end
  end

  @doc """
  Fetches the remote public key for given actor AP ID.
  """
  def fetch_public_key_for_ap_id(ap_id) do
    with {:ok, actor} <- Actor.get_cached_or_fetch(ap_id: ap_id),
         {:ok, public_key} <- public_key_from_data(actor) do
      {:ok, public_key}
    else
      e ->
        error(e)
    end
  end

  def public_key_from_data(actor, key_id \\ nil)

  # publicKey is a list — find the one matching key_id (if provided), else take first
  def public_key_from_data(%{data: %{"publicKey" => keys}}, key_id)
      when is_list(keys) do
    key_obj =
      if is_binary(key_id),
        do: Enum.find(keys, List.first(keys), &(&1["id"] == key_id)),
        else: List.first(keys)

    case key_obj do
      %{"publicKeyPem" => pem} when is_binary(pem) -> {:ok, pem}
      _ -> {:error, "No valid publicKeyPem found in key list"}
    end
  end

  def public_key_from_data(
        %{
          data: %{
            "publicKey" => %{"publicKeyPem" => public_key_pem}
          }
        },
        _key_id
      )
      when is_binary(public_key_pem) do
    {:ok, public_key_pem}
  end

  def public_key_from_data(%{keys: "-----BEGIN PUBLIC KEY-----" <> _ = key} = _actor, _key_id) do
    {:ok, key}
  end

  def public_key_from_data(%{keys: keys} = _actor, _key_id) when not is_nil(keys) do
    public_key_from_private_key(%{keys: keys})
  end

  def public_key_from_data(data, _key_id) do
    error(data, "Public key not found")
  end

  defp public_key_from_private_key(%{keys: keys} = _actor) do
    with {:ok, _, public_key} <- keypair_from_pem(keys) do
      public_key = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)

      # `:public_key.pem_encode/1` ends with a BLANK line (`-----END PUBLIC KEY-----\n\n`), which strict PEM parsers read as residual data starting another block and reject with "PEM error in pre-encapsulation boundary". Lemmy refuses our actor with exactly that, so it cannot verify our signatures. Lemmy, PieFed and Mbin all publish a single trailing newline or none. OpenSSL accepts either.
      # Trimming alone leaves NO line ending, so put exactly one back: RFC 7468 terminates the post-encapsulation boundary with an EOL, and one newline is what the implementations we federate with emit.
      public_key =
        :public_key.pem_encode([public_key]) |> String.trim_trailing() |> Kernel.<>("\n")

      {:ok, public_key}
    end
  end

  def add_public_key(actor, generate_if_missing \\ true)

  def add_public_key(%Actor{local: true, data: _} = actor, generate_if_missing) do
    with {:ok, actor} <-
           if(generate_if_missing, do: ensure_keys_present(actor), else: {:ok, actor}),
         {:ok, public_key} <- public_key_from_private_key(actor) do
      data =
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

      Map.put(actor, :data, put_assertion_method(data, actor))
    else
      e ->
        error(actor, "Could not add public key to actor: #{inspect(e)}")
        actor
    end
  end

  def add_public_key(actor, _) do
    e = "Skip adding public key on non-local or non-actor"
    warn(actor, e)
    # raise e
    actor
  end

  # FEP-521a: our derived Ed25519 key as a `Multikey` in `assertionMethod`, where a verifier of an integrity proof (FEP-8b32) looks for it. Merged into the entries the data already holds, by `id`: other keys (a client's, FEP-ae97) stay, and an entry under OUR key id is always the derived key, whatever the data held there (FEP-fe34: a server must not let a client set or change key objects).
  defp put_assertion_method(data, actor) do
    with {:ok, {public, _private}} <- ed25519_keypair(actor),
         id when is_binary(id) <- data["id"] do
      entry = %{
        "id" => id <> "#ed25519-key",
        "type" => "Multikey",
        "controller" => id,
        "publicKeyMultibase" =>
          Multibase.encode(Multibase.encode_varint(0xED) <> public, :base58btc)
      }

      others =
        data["assertionMethod"]
        |> List.wrap()
        |> Enum.reject(&(is_map(&1) and &1["id"] == entry["id"]))

      Map.put(data, "assertionMethod", others ++ [entry])
    else
      e ->
        warn(e, "Could not add the Ed25519 key to the actor's assertionMethod")
        data
    end
  end

  @doc """
  Checks if an actor struct has a non-nil keys field and generates a PEM if it doesn't.
  """
  def ensure_keys_present(%{keys: keys} = object) when is_binary(keys) do
    {:ok, object}
  end

  def ensure_keys_present(%{local: false} = object) do
    {:ok, object}
  end

  def ensure_keys_present(%Actor{data: %{"type" => type}} = actor) when type != "Tombstone" do
    # The struct we were given may be older than the actor's key: it stays keyless after a key is made and saved, so a caller that still holds it would make another and replace the saved one. So what is stored is asked first, around the cache, which can be as stale as the struct.
    case stored_keys(actor) do
      {:ok, stored} ->
        {:ok, stored}

      :none ->
        warn(actor, "actor has no keys and is local, generate new ones")

        with {:ok, pem} <- generate_rsa_pem(),
             {:ok, actor} <- Adapter.update_local_actor(actor, %{keys: pem}),
             {:ok, actor} <- Actor.set_cache(actor) do
          {:ok, actor}
        else
          e -> error(e, "Could not generate or save keys")
        end
    end
  end

  def ensure_keys_present(object) do
    warn(object, "not an actor, so keys are not applicable")
    {:ok, object}
  end

  # the actor as the host app has it now, if that one has a key
  defp stored_keys(%{username: username}) when is_binary(username) do
    case Adapter.get_actor_by_username(username) do
      {:ok, %{keys: keys} = stored} when is_binary(keys) -> {:ok, stored}
      _ -> :none
    end
  end

  defp stored_keys(_actor), do: :none

  def generate_rsa_pem() do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    pem = :public_key.pem_encode([entry]) |> String.trim_trailing()
    {:ok, pem}
  end

  @doc """
  The Ed25519 key of a local actor, for FEP-8b32 integrity proofs, as `{:ok, {public, private}}` (32 bytes each).

  It is derived, not stored: HKDF-SHA256 over the DER of the actor's RSA private key (the DER, not the PEM text, so line wrapping cannot change it), with no salt and a label, gives the seed. So it is the same every time, needs no migration, and changes if the RSA key does. The actor's id is not an input, so a move to another domain keeps the key. A local actor with no RSA key yet gets one first.

  `{:error, _}` for an actor that is not ours, or has no key.
  """
  def ed25519_keypair(%{local: true} = actor) do
    with {:ok, %{keys: pem}} when is_binary(pem) <- ensure_keys_present(actor),
         {:ok, private_key, _public_key} when not is_nil(private_key) <- keypair_from_pem(pem) do
      seed =
        HKDF.derive(
          :sha256,
          :public_key.der_encode(:RSAPrivateKey, private_key),
          32,
          "",
          @ed25519_label
        )

      {:ok, :crypto.generate_key(:eddsa, :ed25519, seed)}
    else
      other -> error(other, "no Ed25519 key for this actor")
    end
  end

  def ed25519_keypair(_actor), do: {:error, :not_a_local_actor}

  def keypair_from_pem(pem) when is_binary(pem) do
    with [private_key_code] <- :public_key.pem_decode(pem),
         private_key <- :public_key.pem_entry_decode(private_key_code),
         {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} <-
           private_key do
      {:ok, private_key, {:RSAPublicKey, modulus, exponent}}
    else
      {:RSAPublicKey, modulus, exponent} -> {:ok, nil, {:RSAPublicKey, modulus, exponent}}
      error -> error(error)
    end
  end

  def keypair_from_pem(pem) do
    error(pem, "Could not get keys for actor (expected a PEM)")
  end

  def key_id_to_actor_id(key_id) do
    maybe_ap_id =
      key_id
      |> URI.parse()
      |> Map.put(:fragment, nil)
      |> remove_suffix(@known_suffixes)
      |> URI.to_string()

    case cast_uri(maybe_ap_id) do
      {:ok, ap_id} ->
        {:ok, ap_id}

      _ ->
        case ActivityPub.Federator.WebFinger.finger(maybe_ap_id) do
          {:ok, %{"ap_id" => ap_id}} -> {:ok, ap_id}
          _ -> {:error, maybe_ap_id}
        end
    end
  end

  defp remove_suffix(uri, [test | rest]) do
    if not is_nil(uri.path) and String.ends_with?(uri.path, test) do
      Map.put(uri, :path, String.replace(uri.path, test, ""))
    else
      remove_suffix(uri, rest)
    end
  end

  defp remove_suffix(uri, []), do: uri

  def cast_uri(object) when is_binary(object) do
    # Host has to be present and scheme has to be an http scheme (for now)
    case URI.parse(object) do
      %URI{host: nil} -> :error
      %URI{host: ""} -> :error
      %URI{scheme: scheme} when scheme in ["https", "http"] -> {:ok, object}
      _ -> :error
    end
  end

  def public_key_decode(public_key_pem) do
    case :public_key.pem_decode(public_key_pem) do
      [public_key_entry] ->
        {:ok, :public_key.pem_entry_decode(public_key_entry)}

      e ->
        error(e)
        {:error, :pem_decode_error}
    end
  end

  def sign(%{keys: _} = actor, headers, opts \\ []) do
    with {:ok, actor} <- ensure_keys_present(actor),
         {:ok, private_key, public_key} when not is_nil(private_key) <-
           Keys.keypair_from_pem(actor.keys) do
      key_id = actor.data["id"] <> "#main-key"

      :crypto.hash(:sha256, :erlang.term_to_binary(public_key))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)
      |> debug("TEMP: signing as #{key_id} with pub_key fingerprint")

      {:ok, HTTPSignatures.sign(private_key, key_id, headers, opts)}
    end
  end

  def maybe_add_fetch_signature_headers(headers, id, options \\ []) do
    # enabled by default :-)
    if Config.get([:sign_object_fetches], true) do
      format =
        options[:signature_format] || SignaturesAdapter.get_signature_format(id_host(id)) ||
          :cavage

      make_fetch_signature(id, format, options) ++ headers
    else
      headers
    end
  end

  defp id_host(%URI{} = uri), do: ActivityPub.Utils.authority(uri)
  defp id_host(url) when is_binary(url), do: ActivityPub.Utils.authority(url)
  defp id_host(_), do: nil

  defp make_fetch_signature(%URI{} = uri, :rfc9421, options) do
    with {:ok, request_actor} <- options[:current_actor] || Utils.service_actor(),
         {:ok, {sig_input, sig}} <-
           Keys.sign(
             request_actor,
             %{
               "@method" => "GET",
               "@scheme" => uri.scheme || "https",
               "@authority" => http_host(uri),
               "@path" => uri.path || "/",
               "@query" => uri.query
             },
             format: :rfc9421,
             components: ["@method", "@target-uri"]
           ) do
      [{"signature-input", sig_input}, {"signature", sig}]
    else
      other ->
        error(other, "Could not sign the fetch with RFC 9421")
        []
    end
  end

  defp make_fetch_signature(%URI{} = uri, _cavage, options) do
    with {:ok, request_actor} <- options[:current_actor] || Utils.service_actor(),
         date = options[:date] || Utils.format_date(),
         {:ok, signature} <-
           Keys.sign(request_actor, %{
             "(request-target)": "get #{uri.path}",
             host: http_host(uri),
             date: date
           }) do
      [{"signature", signature}, {"date", date}]
    else
      other ->
        error(other, "Could not sign the fetch")
        []
    end
  end

  defp make_fetch_signature(id, format, options) do
    make_fetch_signature(URI.parse(id), format, options)
  end

  def http_host(uri), do: ActivityPub.Utils.authority(uri)
end
