# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Safety.IntegrityProofs do
  @moduledoc """
  Verifies FEP-8b32 object integrity proofs: a signature that travels inside an activity or object, so it can be checked without asking the sender, and still holds when someone else passes the document on.

  `verify/2` returns `{:ok, controller}`, the actor whose key signed it, or an error naming why not. Any error means "this proof does not authenticate the document", and the receiver goes on to the other ways of authenticating it (the HTTP signature, a legacy LD signature, fetching it from its origin). A proof is never a reason to refuse a delivery that could be authenticated otherwise.

  What is checked, in order:

    1. the proof's own fields: `type`, `cryptosuite`, `proofPurpose`, `verificationMethod`, `proofValue`, that it is not a link in a chain, `created`, `expires`, `domain`
    2. who the document belongs to (`actor`, else `attributedTo`), which must be one actor
    3. that the key lives on the same origin as the document (FEP-fe34)
    4. the key, from the actor's `assertionMethod` (`ActivityPub.Safety.IntegrityProofs.Resolver`), and that its controller is the owner
    5. the signature, over the hashes `ActivityPub.Safety.IntegrityProofs.Proof` builds

  Cheap checks come first and nothing is fetched until the proof is worth it. A signature that fails against the key we hold is checked once more against a freshly fetched actor, in case the key was rotated, and then it is final.

  A proof does not make a document acceptable by itself. It says who wrote it; whether that actor may do what the document does, and whether the document may sit on its host, is `ActivityPub.Safety.Containment` and the rest of the receiving path.
  """

  import Untangle

  alias ActivityPub.Config
  alias ActivityPub.Safety.IntegrityProofs.{Cryptosuites, Proof, Resolver}
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Safety.Multibase
  alias ActivityPub.Utils

  @domain_check_modes [:strict, :relay, :off]

  # the suites we can sign with 
  # NOTE: `mldsa44-jcs-2024` needs a key OTP cannot derive from a seed, so not available for signing here, but is available for verifying a proof that was made elsewhere with such a key.
  @signing_suites ["eddsa-jcs-2022"]

  @doc """
  Puts a proof on a document that `actor`, one of ours, authored, signed with the actor's derived Ed25519 key (`ActivityPub.Safety.Keys.ed25519_keypair/1`), the same construction `verify/2` checks.

  Options: `:cryptosuite` (default the `object_integrity_cryptosuite` setting, `eddsa-jcs-2022`), and `:created`, an ISO 8601 UTC time (default now, to the second).

  Errors: `{:error, :already_signed}` (a document carries at most one proof), `{:error, :unsupported_cryptosuite}`, `{:error, :not_the_owner}` (the document is somebody else's: a copy of it that we relay is not ours to sign), and whatever `Keys.ed25519_keypair/1` says for an actor that is not ours.
  """
  @spec sign(map(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def sign(document, actor, opts \\ [])

  def sign(%{"proof" => _proof}, _actor, _opts), do: {:error, :already_signed}

  def sign(%{} = document, actor, opts) do
    suite = opts[:cryptosuite] || Config.get(:object_integrity_cryptosuite, "eddsa-jcs-2022")

    with true <- suite in @signing_suites || {:error, :unsupported_cryptosuite},
         {:ok, owner} <- owner(document),
         true <- owner == Utils.ap_id(actor) || {:error, :not_the_owner},
         {:ok, {_public, private}} <- Keys.ed25519_keypair(actor),
         proof = proof_to_sign(document, suite, owner, opts),
         {:ok, hash} <- Proof.hash_data(document, proof) do
      signature = :crypto.sign(:eddsa, :none, hash, [private, :ed25519])

      {:ok,
       Map.put(
         document,
         "proof",
         Map.put(proof, "proofValue", Multibase.encode(signature, :base58btc))
       )}
    end
  end

  # no copy of the document's `@context` in the proof, as Mitra signs: Mastodon's and Mitra's verifiers hash a proof without one as given, and the document's `@context` is covered anyway, as it is hashed with the document. The copy, which the spec advises, only repeated it on every signed document
  defp proof_to_sign(_document, suite, owner, opts) do
    %{
      "type" => "DataIntegrityProof",
      "cryptosuite" => suite,
      "verificationMethod" => owner <> "#ed25519-key",
      "proofPurpose" => "assertionMethod",
      "created" => opts[:created] || created_now()
    }

    # case document["@context"] do
    #   nil -> proof
    #   context -> Map.put(proof, "@context", context)
    # end
  end

  @doc "The time a proof is made at (its `created`): ISO 8601 UTC to the second, the usual form, which strict parsers expect. A publish takes it once, so all its documents get the same."
  def created_now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc "Whether a document carries a proof (or several) to look at."
  @spec has_proof?(term()) :: boolean()
  def has_proof?(%{"proof" => %{} = proof}), do: map_size(proof) > 0
  def has_proof?(%{"proof" => [_ | _] = proofs}), do: Enum.any?(proofs, &is_map/1)
  def has_proof?(_), do: false

  @doc """
  How a proof's `domain` is checked, from the `object_integrity_domain_check` setting (`:relay` when unset):

    * `:strict`: the proof must name our own origin
    * `:relay`: or, for an activity a group relayed to us, the group's
    * `:off`: `domain` is not looked at

  A proof with no `domain` passes in all three.
  """
  @spec domain_check_mode() :: :strict | :relay | :off
  def domain_check_mode do
    case Config.get(:object_integrity_domain_check, :relay) do
      mode when mode in @domain_check_modes -> mode
      "strict" -> :strict
      "relay" -> :relay
      "off" -> :off
      _ -> :relay
    end
  end

  # Failures of `verify/2` that are evidence AGAINST the document: the bytes do not match the signature, the proof is another actor's, the key is not on the document's origin, or the proof names contexts the document does not have. Every other failure only means the proof cannot be checked here (an unknown suite, a key that cannot be fetched, a `domain` that is not ours, an expired proof, a field missing), and FEP-8b32 says to ignore such a proof and try other ways to authenticate.
  @evidence_against [
    :bad_signature,
    :controller_not_owner,
    :key_origin_mismatch,
    :context_mismatch
  ]

  @doc """
  What a receiver wants to know about a document's proof: whether it can be relied on, is evidence against the document, or tells nothing.

    * `{:valid, controller}`: it verifies, and `controller` made the document
    * `{:invalid, reason}`: it does not, and the reason is evidence against the document, as a broken LD signature is. A relayed copy carrying one is not to be trusted
    * `{:unverifiable, reason}`: it cannot be checked here; carry on as if it were not there
    * `:none`: there is no proof

  A `Create` or `Update` with no proof of its own is judged by its object's proof, when the object belongs to the activity's actor.

  Takes the options of `verify/2`.
  """
  @spec check(term(), keyword()) ::
          {:valid, String.t()} | {:invalid, atom()} | {:unverifiable, atom()} | :none
  def check(document, opts \\ []) do
    if has_proof?(document) do
      classify(verify(document, opts))
    else
      check_object(document, opts)
    end
  end

  defp classify({:ok, controller}), do: {:valid, controller}
  defp classify({:error, reason}) when reason in @evidence_against, do: {:invalid, reason}
  defp classify({:error, reason}), do: {:unverifiable, reason}

  # A `Create` or `Update` may carry its proof on the object alone (FEP-8b32 allows either), so with no proof of its own the object's proof stands for it. Only when the object belongs to the activity's actor: an object of someone else stands on its own proof and says nothing about the activity.
  defp check_object(%{"type" => type, "object" => %{} = object} = document, opts)
       when type in ["Create", "Update"] do
    with true <- has_proof?(object),
         {:ok, owner} <- owner(document),
         {:ok, ^owner} <- owner(object) do
      classify(verify(object, opts))
    else
      _ -> :none
    end
  end

  defp check_object(_document, _opts), do: :none

  @doc """
  Verifies the proof (or proofs) on a document.

  Options:

    * `:relayed_by`: the actor id of the group that passed this on, for the `:relay` domain check
    * `:domain_check`: replaces the setting, see `domain_check_mode/0`
    * `:origin`: our own origin, for the `domain` check (default: this instance's)
  """
  @spec verify(term(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def verify(document, opts \\ [])

  def verify(%{"proof" => proof} = document, opts) when is_map(proof) or is_list(proof) do
    case proof |> List.wrap() |> Enum.filter(&is_map/1) do
      [] ->
        {:error, :no_proof}

      proofs ->
        with {:ok, owner} <- owner(document) do
          verify_any(document, proofs, owner, opts)
        end
    end
  end

  def verify(_document, _opts), do: {:error, :no_proof}

  # one proof that verifies is enough (FEP-8b32 says a document should carry no more than one, but a signer moving between cryptosuites may send several); the error shown is the first one's
  defp verify_any(document, proofs, owner, opts) do
    Enum.reduce_while(proofs, nil, fn proof, first_error ->
      case verify_one(document, proof, owner, opts) do
        {:ok, controller} -> {:halt, {:ok, controller}}
        {:error, _} = error -> {:cont, first_error || error}
      end
    end)
  end

  defp verify_one(document, proof, owner, opts) do
    verification_method = proof["verificationMethod"]

    with :ok <- check_fields(proof, opts),
         :ok <- check_origin(verification_method, document, owner),
         {:ok, candidates} <- Proof.hash_candidates(document, proof),
         {:ok, signature} <- Multibase.decode(proof["proofValue"]),
         {:ok, resolved} <- resolve(verification_method, owner, false),
         :ok <- check_controller(resolved, owner) do
      check_signature(proof["cryptosuite"], candidates, signature, resolved, fn ->
        resolve(verification_method, owner, true)
      end)
    end
  end

  # --- the proof's own fields ---

  defp check_fields(proof, opts) do
    with :ok <- ensure(proof["type"] == "DataIntegrityProof", :unsupported_proof_type),
         :ok <- ensure(proof["cryptosuite"] in Cryptosuites.supported(), :unsupported_cryptosuite),
         :ok <- ensure(proof["proofPurpose"] == "assertionMethod", :wrong_proof_purpose),
         :ok <-
           ensure(
             is_binary(proof["verificationMethod"]) and proof["verificationMethod"] != "",
             :missing_verification_method
           ),
         :ok <-
           ensure(
             is_binary(proof["proofValue"]) and proof["proofValue"] != "",
             :missing_proof_value
           ),
         :ok <- ensure(is_nil(proof["previousProof"]), :unsupported_proof_chain),
         :ok <- check_created(proof["created"]),
         :ok <- check_expires(proof["expires"]) do
      check_domain(proof["domain"], opts)
    end
  end

  defp ensure(true, _error), do: :ok
  defp ensure(false, error), do: {:error, error}

  defp check_created(nil), do: :ok

  defp check_created(created) do
    case parse_time(created) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_created}
    end
  end

  defp check_expires(nil), do: :ok

  defp check_expires(expires) do
    case parse_time(expires) do
      {:ok, at} -> ensure(DateTime.compare(at, DateTime.utc_now()) == :gt, :expired_proof)
      :error -> {:error, :invalid_expires}
    end
  end

  # xsd:dateTimeStamp. Offset-less times are read as UTC, which Data Integrity allows a verifier to do; Mitra writes nanoseconds, which Elixir's parser does not take, and nothing here needs more than microseconds
  defp parse_time(time) when is_binary(time) do
    time = Regex.replace(~r/(\.\d{6})\d+/, time, "\\1")

    case DateTime.from_iso8601(time) do
      {:ok, at, _offset} ->
        {:ok, at}

      _ ->
        case NaiveDateTime.from_iso8601(time) do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          _ -> :error
        end
    end
  end

  defp parse_time(_), do: :error

  # a `domain` says where the proof was made to be used. Replaying a proof at a host it was not made for is refused, but a group relays an author's activity to hosts the author's server never heard of, so in `:relay` mode the group's own host counts too: the one an author could have bound a proof to
  defp check_domain(nil, _opts), do: :ok

  defp check_domain(domain, opts) do
    mode = opts[:domain_check] || domain_check_mode()
    own = opts[:origin] || ActivityPub.Web.base_url()

    allowed =
      case {mode, opts[:relayed_by]} do
        {:off, _} -> :any
        {:relay, relayed_by} when is_binary(relayed_by) -> [own, relayed_by]
        _ -> [own]
      end

    if allowed == :any or names_any?(domain, allowed),
      do: :ok,
      else: {:error, :wrong_domain}
  end

  defp names_any?(domain, allowed) do
    allowed = Enum.map(allowed, &authority/1)
    domain |> List.wrap() |> Enum.any?(&(is_binary(&1) and authority(&1) in allowed))
  end

  # "our.example", "https://our.example" and "https://our.example/pub/group/1" all mean our.example
  defp authority(url), do: url |> Utils.authority() |> String.downcase()

  # --- who it belongs to ---

  @doc """
  Who a document belongs to, so whose signature can vouch for it (FEP-fe34): an actor document's own `id`, an activity's `actor`, anything else's `attributedTo`. `{:ok, owner}`, or `{:error, :multiple_owners}` for several (not covered by FEP-fe34, and taking the first would let a second one ride on someone else's key) or `{:error, :no_owner}`. The rule for an LD signature too (`ActivityPub.Safety.author_signature/2`).
  """
  def owner(document) do
    cond do
      actor_document?(document) -> single_owner(document["id"])
      owner = document["actor"] || document["attributedTo"] -> single_owner(owner)
      true -> {:error, :no_owner}
    end
  end

  defp actor_document?(%{"id" => id, "type" => type}) when is_binary(id),
    do: type |> List.wrap() |> Enum.any?(&(&1 in Config.supported_actor_types()))

  defp actor_document?(_), do: false

  defp single_owner(owner) when is_binary(owner), do: {:ok, owner}
  defp single_owner(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp single_owner([one]), do: single_owner(one)
  defp single_owner([_, _ | _]), do: {:error, :multiple_owners}
  defp single_owner(_), do: {:error, :no_owner}

  # FEP-fe34: the key must be on the origin of the document it signs. A `did:key` has no origin, and is vouched for by the actor listing it instead
  defp check_origin("did:key:" <> _, _document, _owner), do: :ok

  defp check_origin(verification_method, document, owner) do
    reference = if is_binary(document["id"]), do: document["id"], else: owner

    ensure(
      origin(verification_method) != nil and origin(verification_method) == origin(reference),
      :key_origin_mismatch
    )
  end

  defp origin(url), do: Utils.origin(url)

  defp check_controller(%{controller: controller}, owner),
    do: ensure(controller == owner, :controller_not_owner)

  # --- the key, and the signature ---

  defp resolve(verification_method, owner, fresh?),
    do: Resolver.resolve(verification_method, owner: owner, fresh: fresh?)

  # tried against the key we hold; if that fails, once against the actor as its server serves it now, since a rotated key shows up as nothing but a bad signature
  defp check_signature(cryptosuite, candidates, signature, resolved, fetch_fresh) do
    case verify_candidates(cryptosuite, candidates, signature, resolved.key) do
      :ok ->
        {:ok, resolved.controller}

      {:error, :bad_signature} ->
        with {:ok, fresh} <- fetch_fresh.(),
             :ok <- ensure(fresh.key != resolved.key, :bad_signature),
             :ok <- verify_candidates(cryptosuite, candidates, signature, fresh.key) do
          debug(fresh.controller, "the key had been rotated")
          {:ok, fresh.controller}
        else
          _ -> {:error, :bad_signature}
        end

      {:error, _} = error ->
        error
    end
  end

  defp verify_candidates(cryptosuite, candidates, signature, key) do
    Enum.reduce_while(candidates, {:error, :bad_signature}, fn hash, _ ->
      case Cryptosuites.verify(cryptosuite, hash, signature, key) do
        :ok -> {:halt, :ok}
        {:error, :bad_signature} = error -> {:cont, error}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
