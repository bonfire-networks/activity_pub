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

  @known_suffixes ["/publickey", "/main-key"]

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

  def public_key_from_data(%{
        data: %{
          "publicKey" => %{"publicKeyPem" => public_key_pem}
        }
      })
      when is_binary(public_key_pem) do
    {:ok, public_key_pem}
  end

  def public_key_from_data(%{keys: "-----BEGIN PUBLIC KEY-----" <> _ = key} = _actor) do
    {:ok, key}
  end

  def public_key_from_data(%{keys: keys} = _actor) when not is_nil(keys) do
    public_key_from_private_key(%{keys: keys})
  end

  def public_key_from_data(data) do
    error(data, "Public key not found")
  end

  defp public_key_from_private_key(%{keys: keys} = _actor) do
    with {:ok, _, public_key} <- keypair_from_pem(keys) do
      public_key = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)
      public_key = :public_key.pem_encode([public_key])

      {:ok, public_key}
    end
  end

  def add_public_key(actor, generate_if_missing \\ true)

  def add_public_key(%Actor{local: true, data: _} = actor, generate_if_missing) do
    with {:ok, actor} <-
           if(generate_if_missing, do: ensure_keys_present(actor), else: {:ok, actor}),
         {:ok, public_key} <- public_key_from_private_key(actor) do
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

  def add_public_key(actor, _) do
    e = "Skip adding public key on non-local or non-actor"
    warn(actor, e)
    # raise e
    actor
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
    warn(actor, "actor has no keys and is local, generate new ones")

    with {:ok, pem} <- generate_rsa_pem(),
         {:ok, actor} <- Adapter.update_local_actor(actor, %{keys: pem}),
         {:ok, actor} <- Actor.set_cache(actor) |> debug("donz") do
      {:ok, actor}
    else
      e -> error(e, "Could not generate or save keys")
    end
  end

  def ensure_keys_present(object) do
    warn(object, "not an actor, so keys are not applicable")
    {:ok, object}
  end

  def generate_rsa_pem() do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    pem = :public_key.pem_encode([entry]) |> String.trim_trailing()
    {:ok, pem}
  end

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

  def sign(%{keys: _} = actor, headers) do
    with {:ok, actor} <- ensure_keys_present(actor),
         {:ok, private_key, _} when not is_nil(private_key) <- Keys.keypair_from_pem(actor.keys),
         signed when is_binary(signed) <-
           HTTPSignatures.sign(private_key, actor.data["id"] <> "#main-key", headers) do
      {:ok, signed}
    end
  end

  def maybe_add_fetch_signature_headers(headers, id, date \\ nil) do
    # enabled by default :-)
    if Config.get([:sign_object_fetches], true) do
      make_fetch_signature(id, date) ++ headers
    else
      headers
    end
  end

  defp make_fetch_signature(%URI{} = uri, date) do
    # TODO: optionally fetch with the signature of user doing the request?
    with {:ok, service_actor} <- Utils.service_actor(),
         date = date || Utils.format_date(),
         {:ok, signature} <-
           Keys.sign(service_actor, %{
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

    # |> debug()
  end

  defp make_fetch_signature(id, date) do
    make_fetch_signature(URI.parse(id), date)
  end

  def http_host(%{host: host, port: port}) when port in [80, 443] do
    host
  end

  def http_host(%{host: host, port: port}) when is_integer(port) or is_binary(port) do
    "#{host}:#{port}"
  end
end
