defmodule ActivityPub.Safety.Keys do
  @moduledoc """
  Handles RSA keys and HTTP signatures
  """
  @behaviour HTTPSignatures.Adapter

  import Untangle
  use Arrows

  alias ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Utils
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Adapter

  @known_suffixes ["/publickey", "/main-key"]

  def add_public_key(%{data: _} = actor) do
    with {:ok, actor} <- ensure_keys_present(actor),
         {:ok, _, public_key} <- keypair_from_pem(actor.keys) do
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
    if actor.local == false or actor.keys do
      debug(actor.keys, "actor has keys or is remote")
      {:ok, actor}
    else
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

  def fetch_public_key(conn) do
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn) |> debug,
         {:ok, actor_id} <- key_id_to_actor_id(kid) |> debug,
         {:ok, public_key} <- Actor.get_public_key_for_ap_id(actor_id) |> debug do
      {:ok, public_key_decode(public_key)}
    else
      e ->
        error(e)
        # return ok so that HTTPSignatures calls `refetch_public_key/1`
        {:ok, nil}
    end
  end

  def refetch_public_key(conn) do
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn),
         {:ok, actor_id} <- key_id_to_actor_id(kid),
         # Ensure the remote actor is freshly fetched before updating
         {:ok, actor} <- Fetcher.fetch_fresh_object_from_id(actor_id) |> debug,
         #  {:ok, actor} <- Actor.update_actor(actor_id) |> debug,
         # FIXME: This might update the actor twice in a row ^
         {:ok, actor} <- Actor.update_actor(actor_id, actor) |> debug,
         {:ok, public_key} <- Actor.get_public_key_for_ap_id(actor) do
      {:ok, public_key_decode(public_key)}
    else
      e ->
        error(e)
    end
  end

  defp public_key_decode(public_key_pem) do
    public_key_pem
    |> :public_key.pem_decode()
    |> hd()
    |> :public_key.pem_entry_decode()
  end

  defp public_key_from_data(data) do
    error(data, "Key not found")
  end

  def sign(actor, headers) do
    with {:ok, actor} <- Keys.ensure_keys_present(actor),
         {:ok, private_key, _} <- Keys.keypair_from_pem(actor.keys),
         signed when is_binary(signed) <-
           HTTPSignatures.sign(private_key, actor.data["id"] <> "#main-key", headers) do
      {:ok, signed}
    end
  end

  def maybe_add_sign_headers(headers, id, date \\ nil) do
    # enabled by default :-)
    if Config.get([:sign_object_fetches], true) do
      date = date || signed_date()
      [make_signature(id, date), {"date", date} | headers]
    else
      headers
    end
  end

  defp make_signature(id, date) do
    uri = URI.parse(id)

    with {:ok, service_actor} <- Utils.service_actor(),
         {:ok, signature} <-
           Keys.sign(service_actor, %{
             "(request-target)": "get #{uri.path}",
             host: uri.host,
             date: date
           }) do
      {"signature", signature}
    end
    |> debug()
  end

  def signed_date, do: signed_date(NaiveDateTime.utc_now(Calendar.ISO))

  def signed_date(%NaiveDateTime{} = date) do
    Timex.format!(date, "{WDshort}, {0D} {Mshort} {YYYY} {h24}:{m}:{s} GMT")
  end
end
