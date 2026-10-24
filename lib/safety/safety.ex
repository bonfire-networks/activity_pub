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
