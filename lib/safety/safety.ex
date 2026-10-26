# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Safety do
  @moduledoc """
  How far a document is to be trusted, as the `authenticated` field of `ActivityPub.Object` says it: whether somebody vouched for it, and by what.

  The values (in the order of their rank, which is the order of the Postgres enum behind the field):

    * `nil`: nothing recorded
    * `:unverified`: checked, no usable proof, nothing fetched
    * `:unfetchable`: we asked the origin and could not reach it
    * `:embedded`: it sits in a document its actor vouched for, but names no owner itself, so the signature is not taken as the owner's
    * `:http_signature`, `:ld_signature`, `:integrity_proof`: signed by its actor
    * `:fetched`: we fetched it from its origin
  """

  require Untangle
  alias ActivityPub.Config
  alias ActivityPub.Object

  # the values of `authenticated` that name a signature of the actor's (a proof, an LD signature, or the HTTP signature of the delivery)
  @by_signature [:http_signature, :ld_signature, :integrity_proof]
  # every value that says somebody vouched for the document
  @vouched [:embedded, :fetched | @by_signature]

  @doc "Whether a value of `authenticated` says somebody vouched for the document (anything but `nil`, `:unverified` and `:unfetchable`)."
  def vouched?(authenticated), do: authenticated in @vouched

  @doc "Whether a value of `authenticated` names a signature of the actor's: a proof, an LD signature, or the HTTP signature of the delivery."
  def by_signature?(authenticated), do: authenticated in @by_signature

  @doc """
  How a document came to be vouched for, as `{authenticated, signed_by}`, from the options its handling carries:

    * `authenticated:` and `signed_by:`, when the receiving path says how and by whom
    * otherwise by how it arrived, see `by_arrival/1`
  """
  def authentication(opts) do
    {opts[:authenticated] || by_arrival(opts), opts[:signed_by]}
  end

  @doc "The same for the object a `Create` carries, which has its own, from `object_authenticated:` and `object_signed_by:`."
  def object_authentication(opts) do
    {opts[:object_authenticated] || by_arrival(opts), opts[:object_signed_by]}
  end

  @doc """
  Whether a copy of a document should replace the one we hold, as `incoming_data` with the `incoming_authenticated` value it arrived with, against the stored `%ActivityPub.Object{}`.

    * a copy somebody vouched for replaces the stored one, whatever that one's value, unless it is provably older: its date (`updated`, else `published`) before the stored copy's. An equal date, or no date on either, replaces
    * a copy nobody vouched for never replaces one somebody did, and replaces another such copy only when it is provably newer: its date after the stored copy's. An equal date, or no date on either, does not
    * an identical copy, with the same value, has nothing to replace
  """
  def replaces?(
        %{data: stored_data, authenticated: stored_authenticated},
        incoming_data,
        incoming_authenticated
      )
      when is_map(incoming_data) do
    cond do
      incoming_data == stored_data and incoming_authenticated == stored_authenticated -> false
      vouched?(incoming_authenticated) -> compare_dates(incoming_data, stored_data) != :lt
      vouched?(stored_authenticated) -> false
      true -> compare_dates(incoming_data, stored_data) == :gt
    end
  end

  def replaces?(_stored, _incoming_data, _incoming_authenticated), do: false

  # `:lt`, `:eq` or `:gt` for the incoming copy's date against the stored one's; `:unknown` when either has none
  defp compare_dates(incoming, stored) do
    with {:ok, incoming_date} <- document_date(incoming),
         {:ok, stored_date} <- document_date(stored) do
      DateTime.compare(incoming_date, stored_date)
    else
      _ -> :unknown
    end
  end

  defp document_date(%{} = data) do
    with date when is_binary(date) <- data["updated"] || data["published"],
         {:ok, datetime, _offset} <- DateTime.from_iso8601(date) do
      {:ok, datetime}
    else
      _ -> :error
    end
  end

  defp document_date(_), do: :error

  @doc """
  Whether a document as it reached us carries its author's own signature, one that holds wherever it is passed on to (unlike the HTTP signature of its delivery): `{:ok, :integrity_proof}` or `{:ok, :ld_signature}` once checked, `:none` with neither, or why it does not hold.

  With the `authenticated` value its delivery was accepted by, nothing is checked again when that was this signature.
  """
  def author_signature(received, authenticated \\ nil)

  def author_signature(_received, authenticated)
      when authenticated in [:integrity_proof, :ld_signature],
      do: {:ok, authenticated}

  def author_signature(received, _authenticated) do
    cond do
      ActivityPub.Safety.IntegrityProofs.has_proof?(received) ->
        case ActivityPub.Safety.IntegrityProofs.check(received) do
          {:valid, _controller} -> {:ok, :integrity_proof}
          other -> other
        end

      ActivityPub.Safety.LinkedDataSignatures.has_verifiable_signature?(received) ->
        case ActivityPub.Safety.LinkedDataSignatures.verify(received) do
          {:ok, _creator} -> {:ok, :ld_signature}
          other -> other
        end

      true ->
        :none
    end
  end

  @doc """
  Whether a result of `author_signature/2` is evidence against the document: a proof (FEP-8b32) or LD signature that does not hold, as opposed to none, or one we cannot check (a key we cannot find, a cryptosuite we do not support), which counts as none.
  """
  def broken_signature?({:invalid, _reason}), do: true
  def broken_signature?({:error, :invalid_signature}), do: true
  def broken_signature?(_result), do: false

  # How far a delivery is trusted by what signed it is `config :activity_pub, :incoming_signatures`, one part per case below. A signature we cannot check (a key we cannot find, a cryptosuite we do not support) counts as none.

  @doc """
  Whether a delivery with no signature of any kind (no HTTP signature, no proof, no LD signature), which its origin does not serve either, is accepted anyway: `incoming_signatures: [unsigned: :accept]`. `:reject` (the default) refuses it.
  """
  def accept_unsigned?, do: Config.get([:incoming_signatures, :unsigned], :reject) == :accept

  @doc """
  Whether a delivery with a signature that does not hold, and nothing else that vouches for it (an HTTP signature still invalid once the key is fetched again, or a broken proof or LD signature with no valid HTTP signature), which its origin does not serve either, is accepted anyway: `incoming_signatures: [invalid: :accept]`. `:reject` (the default) refuses it.
  """
  def accept_invalid?, do: Config.get([:incoming_signatures, :invalid], :reject) == :accept

  @doc """
  What is done with a delivery that is partly invalid: one signature holds and another does not. Its HTTP signature holds, which is always its author's own server's (one by anybody else is not counted as valid, see `ActivityPub.Web.Plugs.MappedSignatureToIdentityPlug`), but its proof or LD signature does not (`broken_signature?/1`): `incoming_signatures: [partly_invalid: ...]`.

    * `:accept` (the default): accepted on the HTTP signature, as Mastodon does with a broken LD signature, so a server whose proofs are broken but whose HTTP signatures work keeps federating. FEP-8b32 says a proof "MUST be given precedence over HTTP signature", which this does not do
    * `:refetch`: the copy its origin serves instead, refused when it serves none
    * `:reject`: refused
  """
  def partly_invalid do
    case Config.get([:incoming_signatures, :partly_invalid], :accept) do
      value when value in [:accept, :refetch, :reject] ->
        value

      other ->
        Untangle.warn(other, "unknown incoming_signatures partly_invalid, using :accept")
        :accept
    end
  end

  @doc """
  Whether `received`, somebody else's activity as it reached us, is vouched for by its author's own proof or LD signature (`author_signature/2`), for whoever passes it on unchanged (a group relaying it, inbox forwarding): `{:ok, :integrity_proof | :ld_signature}`, `:none`, or why it does not hold.

  `stored` is that activity as we hold it (an `ActivityPub.Object`). Accepted by its proof or signature, nothing is checked again. Accepted another way (its HTTP signature, which does not cover what is passed on), it is checked now, and when it holds, `stored`, and its object when that is the same author's, are marked as vouched for by it, so it is checked once whoever asks.
  """
  def vouched_by_signature(%Object{authenticated: authenticated} = stored, received) do
    case author_signature(received, authenticated) do
      # vouched for by it already
      {:ok, ^authenticated} = vouched ->
        vouched

      {:ok, by_signature} = vouched ->
        mark_vouched_by_signature(stored, by_signature)
        vouched

      other ->
        other
    end
  end

  defp mark_vouched_by_signature(%Object{data: data} = activity, authenticated) do
    Object.do_update_existing(activity, %{authenticated: authenticated})

    # the object is covered by the same signature, and vouched for by it when it is the activity's actor's (as an object embedded by its owner inherits the activity's value at receipt)
    with object_id when is_binary(object_id) <- Object.get_ap_id(data["object"]),
         {:ok, %Object{} = object} <- Object.get_cached(ap_id: object_id),
         true <- Object.actor_from_data(object.data) == data["actor"] do
      Object.do_update_existing(object, %{authenticated: authenticated})
    end
  end

  @doc """
  What how a document arrived says on its own: `:fetched` when we fetched it from its origin (`already_fetched:`), `:unverified` when it was delivered (`from_inbox:`) and nobody vouched for it, otherwise `nil`: ours, or by no delivery.
  """
  def by_arrival(opts) do
    cond do
      opts[:already_fetched] -> :fetched
      opts[:from_inbox] -> :unverified
      true -> nil
    end
  end
end
