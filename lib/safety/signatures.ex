defmodule ActivityPub.Safety.Signatures do
  @behaviour HTTPSignatures.Adapter
  import Untangle
  alias ActivityPub.Actor
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Federator.Fetcher

  @known_suffixes ["/publickey", "/main-key"]

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
      {:ok, public_key}
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
         {:ok, actor} <- Fetcher.fetch_fresh_object_from_id(actor_id) |> info,
         #  {:ok, actor} <- Actor.update_actor(actor_id) |> info,
         # FIXME: This might update the actor twice in a row ^
         {:ok, actor} <- Actor.update_actor(actor_id, actor) |> debug,
         {:ok, public_key} <- Actor.get_public_key_for_ap_id(actor) do
      {:ok, public_key}
    else
      e ->
        error(e)
    end
  end

  def sign(actor, headers) do
    # with {:ok, actor} <- Actor.ensure_keys_present(actor),
    with {:ok, private_key, _} <- Keys.keys_from_pem(actor.keys) do
      HTTPSignatures.sign(private_key, actor.data["id"] <> "#main-key", headers)
    end
  end

  def signed_date, do: signed_date(NaiveDateTime.utc_now(Calendar.ISO))

  def signed_date(%NaiveDateTime{} = date) do
    Timex.format!(date, "{WDshort}, {0D} {Mshort} {YYYY} {h24}:{m}:{s} GMT")
  end
end
