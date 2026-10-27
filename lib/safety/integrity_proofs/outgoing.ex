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

  alias ActivityPub.Config
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
  Signs `document` for `actor`, returning it with the `cache` to pass to the next call.

  `created` is the time of the proofs, the same for all the documents of one publish.
  """
  @spec sign(map(), map(), String.t(), map()) :: {map(), map()}
  def sign(document, actor, created, cache \\ %{})

  def sign(%{"type" => type, "object" => %{} = object} = document, actor, created, cache)
      when type in ["Create", "Update"] do
    context = signing_context(document)

    {object, cache} = sign_one(object, context, actor, created, cache)

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
