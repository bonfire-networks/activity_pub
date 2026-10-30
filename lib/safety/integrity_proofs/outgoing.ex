# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Safety.IntegrityProofs.Outgoing do
  @moduledoc """
  Signs what we send (FEP-8b32), as the publisher hands it over, once each inbox's document is final: nothing may touch the body after this.

    * a `Create` or `Update`: the object first, then the activity around it. The object's proof is the durable one (it is fetched by id, embedded in boosts and relays); the activity's is the one Mastodon reads, on a top-level activity from someone other than the HTTP signer
    * any other activity: the activity

  A document we did not author is returned exactly as it came: a remote author's `Create` that our group relays carries its author's proof, if any, and is not ours to sign (`IntegrityProofs.sign/3` says `:not_the_owner`). A signing that fails sends the document unsigned, with a warning: a federation that works without proofs is better than one that stops.

  Documents that come out the same for several inboxes are signed once: the publisher passes `cache` from one inbox to the next, and one publish has one `created`.
  """

  import Untangle

  alias ActivityPub.Actor
  alias ActivityPub.Config
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Safety.IntegrityProofs
  alias ActivityPub.Safety.Keys

  # added to the `@context` of what is signed: it defines `DataIntegrityProof` and `proof`
  @context "https://w3id.org/security/data-integrity/v2"

  @doc "Whether we sign what we send: the `sign_object_integrity_proofs` setting, on by default."
  def enabled?, do: Config.get(:sign_object_integrity_proofs, true) != false

  @doc """
  The actor to sign a publish as, with its RSA key in place (made first when it has none yet), or `nil` when that cannot be had.

  The Ed25519 key is derived from the RSA key, so the keys are made (or read, `Keys.ensure_keys_present/1` takes what is stored if there is a key already) once per publish, and everything of that publish is signed with the actor this returns, rather than looking them up again for each document.
  """
  def signer(actor) do
    case Keys.ensure_keys_present(actor) do
      {:ok, %{keys: keys} = actor} when is_binary(keys) ->
        actor

      other ->
        warn(other, "No keys to sign with, sending unsigned")
        nil
    end
  end

  @doc """
  The signed public form of a local object, to be kept with it (`data_received`) when it is stored: the document as `ActivityPub.Web.ObjectView` serves it (`Transformer.prepare_outgoing/2`, then without `bto` and `bcc`), signed by its owner. `{:ok, signed}`, or `:error` when signing is off, the owner is not a local actor, or it has no key yet.

  Signed once here, and not on each fetch, so what is served is the one document that verifies. Never makes the actor's keys: that saves the actor (and generates an RSA key), which is not for storing an object to do, and which published an `Update` of the actor into its outbox. An actor with no key yet has its objects signed when they are delivered, as before.
  """
  def sign_stored(%{} = data) do
    with true <- enabled?(),
         {:ok, document} <- Transformer.prepare_outgoing(data),
         document = Transformer.preserve_privacy_of_outgoing(document, nil, :public),
         {:ok, owner} <- IntegrityProofs.owner(document),
         {:ok, %{local: true, keys: keys} = actor} when is_binary(keys) <-
           Actor.get_cached(ap_id: owner),
         %{} = signer <- signer(actor),
         {%{"proof" => _} = signed, _cache} <- sign(document, signer, created_now()) do
      {:ok, signed}
    else
      _ -> :error
    end
  end

  # The object of one of our `Create`s as stored with its proof (`sign_stored/1`), when this inbox's copy of it is that document: the same bytes as `GET` serves, and a proof made once. Only when the copy, without its `@context` (the activity's goes in at signing), is the stored one without its `proof` and `@context`; a copy the privacy step changed for this inbox (a hidden recipient folded into `cc`, a rewritten URL) is not, and is signed over its own bytes.
  defp stored_signed(%{"id" => id} = copy) when is_binary(id) do
    with {:ok, %{local: true, data_received: %{"id" => ^id, "proof" => _} = stored}} <-
           ActivityPub.Object.get_cached(ap_id: id),
         true <- Map.drop(stored, ["proof", "@context"]) == Map.delete(copy, "@context") do
      stored
    else
      _ -> nil
    end
  end

  defp stored_signed(_copy), do: nil

  defp created_now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc """
  Signs `document` for `actor`, returning it with the `cache` to pass to the next call.

  `created` is the time of the proofs, the same for all the documents of one publish.
  """
  @spec sign(map(), map(), String.t(), map()) :: {map(), map()}
  def sign(document, actor, created, cache \\ %{})

  def sign(%{"type" => type, "object" => %{} = object} = document, actor, created, cache)
      when type in ["Create", "Update"] do
    context = signing_context(document)

    {object, cache} =
      case stored_signed(object) do
        %{} = stored -> {stored, cache}
        nil -> sign_one(object, context, actor, created, cache)
      end

    document
    |> Map.put("object", object)
    |> sign_one(context, actor, created, cache)
  end

  def sign(%{} = document, actor, created, cache),
    do: sign_one(document, signing_context(document), actor, created, cache)

  def sign(other, _actor, _created, cache), do: {other, cache}

  # the same unsigned document, the same proof. What is signed has the context that defines the proof; what is skipped is returned untouched
  defp sign_one(document, context, actor, created, cache) do
    signable = Map.put(document, "@context", context)

    result =
      case Map.fetch(cache, signable) do
        {:ok, cached} -> cached
        :error -> IntegrityProofs.sign(signable, actor, created: created)
      end

    case result do
      {:ok, signed} ->
        {signed, Map.put(cache, signable, result)}

      # not ours, or signed already
      {:error, reason} when reason in [:not_the_owner, :already_signed] ->
        {document, cache}

      {:error, reason} ->
        warn(reason, "Could not sign an outgoing document, sending it unsigned")
        {document, Map.put(cache, signable, result)}
    end
  end

  defp signing_context(document) do
    context = List.wrap(document["@context"])
    if @context in context, do: context, else: context ++ [@context]
  end
end
