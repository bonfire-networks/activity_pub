# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Federator.Forwarder do
  @moduledoc """
  Inbox forwarding (ActivityPub 7.1.2): a reply that reaches us in one of our users' threads is passed on to their followers on other servers, who would otherwise see the post but not the conversation under it. So are an `Update` and a `Delete` of such a reply.

  Only what its author signed (an FEP-8b32 proof, or an LD signature) and that holds, since it is passed on exactly as it reached us and a receiver has to be able to trust it came from its author and not from us. Only public or unlisted, and never our own (that is published, not forwarded).

  It goes to the remote followers of every local author up the reply chain, and of the actors the adapter names (`ActivityPub.Federator.Adapter.forward_to_followers_of_actors/2`), each inbox once, leaving out the sender's and every inbox the author addressed, which have it already. Signed as one of those local actors: any will do, since a receiver trusts the author's own signature on it.
  """
  import Untangle

  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias ActivityPub.Safety
  alias ActivityPub.Utils
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.APPublisher
  alias ActivityPub.Federator.Publisher

  @forwarded_types ["Create", "Update", "Delete"]

  @doc """
  Whom a received activity is forwarded to, and as whom: `{:ok, %{inboxes: inboxes, signer: actor}}`, or `{:skip, reason}`.

  Asked before the activity is handled, since a `Delete` takes away the reply it is found through. `opts` are the delivery's (`authenticated:`, to not check the author's signature again when it was accepted by it).
  """
  def recipients(received, opts \\ [])

  def recipients(%{"type" => type} = received, opts) when type in @forwarded_types do
    # asked of every received `Create`, `Update` and `Delete`, so the lookups come first and the signature, the costly check, last
    with {:ok, sender} <- remote_sender(received),
         :ok <- public(received),
         :ok <- not_held_already(received),
         {:ok, post} <- replied_to(received),
         {:ok, [signer | _] = actors} <- forward_to_followers_of(post, received),
         :ok <- signed(received, opts),
         {:ok, inboxes} <- inboxes(actors, sender, received) do
      {:ok, %{inboxes: inboxes, signer: signer}}
    end
  end

  def recipients(_received, _opts), do: {:skip, :not_forwarded_type}

  @doc """
  Queues `received`, exactly as it reached us, for each inbox of the `recipients/2` asked before handling it, signed as their signer: only when the handling accepted it (`result` is `{:ok, _}`).

  Each decision is told as a telemetry event, `[:activity_pub, :forwarder, :decided]`, with the number of inboxes (`%{inboxes: n}`) and, as metadata, the activity's `activity_id` and `activity_type` and the `decision`: `{:ok, %{inboxes: inboxes}}`, or `{:skip, reason}` (`:not_handled` when the handling refused it), so what was forwarded, and why not, can be seen.
  """
  def maybe_forward(received, result, recipients) do
    decision = decision(result, recipients)

    :telemetry.execute(
      [:activity_pub, :forwarder, :decided],
      %{inboxes: inboxes_count(decision)},
      %{activity_id: received["id"], activity_type: received["type"], decision: decision}
    )

    forward(received, recipients, decision)
  end

  defp inboxes_count({:ok, %{inboxes: inboxes}}), do: length(inboxes)
  defp inboxes_count(_skip), do: 0

  defp decision({:ok, _}, {:ok, %{inboxes: inboxes}}), do: {:ok, %{inboxes: inboxes}}
  defp decision(_result, {:ok, _}), do: {:skip, :not_handled}
  defp decision(_result, {:skip, _} = skip), do: skip
  defp decision(_result, other), do: {:skip, other}

  defp forward(received, {:ok, %{signer: signer}}, {:ok, %{inboxes: inboxes}}) do
    json = Jason.encode!(received)

    for inbox <- inboxes do
      Publisher.enqueue_one(APPublisher, signer, %{
        inbox: inbox,
        json: json,
        actor_username: Map.get(signer, :username),
        actor_id: Map.get(signer, :id),
        actor_ap_id: signer.data["id"],
        id: received["id"]
      })
    end
  end

  defp forward(_received, _recipients, _decision), do: []

  # a copy delivered again, of an activity we hold, was forwarded when it first came
  defp not_held_already(%{"id" => id}) when is_binary(id) do
    case Object.get_cached(ap_id: id) do
      {:ok, %Object{}} -> {:skip, :held_already}
      _ -> :ok
    end
  end

  defp not_held_already(_received), do: :ok

  defp remote_sender(%{"actor" => actor}) do
    case Actor.get_cached(ap_id: Utils.ap_id(actor)) do
      {:ok, %Actor{local: false} = sender} -> {:ok, sender}
      {:ok, %Actor{}} -> {:skip, :ours}
      _ -> {:skip, :unknown_sender}
    end
  end

  defp remote_sender(_received), do: {:skip, :unknown_sender}

  defp public(received),
    do: if(Utils.public?(received), do: :ok, else: {:skip, :not_public})

  defp signed(received, opts) do
    case Safety.author_signature(received, opts[:authenticated]) do
      {:ok, _authenticated} -> :ok
      :none -> {:skip, :unsigned}
      other -> {:skip, {:signature_does_not_hold, other}}
    end
  end

  # the post a reply replies to, from the reply it carries, or for an `Update` or `Delete` that names it by id, from the copy we hold
  defp replied_to(%{"object" => object}) do
    with in_reply_to when is_binary(in_reply_to) <- in_reply_to(object),
         {:ok, %Object{} = post} <- Object.get_cached(ap_id: in_reply_to) do
      {:ok, post}
    else
      _ -> {:skip, :not_a_reply_we_hold}
    end
  end

  defp replied_to(_received), do: {:skip, :not_a_reply_we_hold}

  defp in_reply_to(%{"inReplyTo" => in_reply_to}) when not is_nil(in_reply_to),
    do: Object.get_ap_id(in_reply_to)

  defp in_reply_to(object) do
    with id when is_binary(id) <- Object.get_ap_id(object),
         {:ok, %Object{data: %{"inReplyTo" => in_reply_to}}} when not is_nil(in_reply_to) <-
           Object.get_cached(ap_id: id) do
      Object.get_ap_id(in_reply_to)
    else
      _ -> nil
    end
  end

  defp forward_to_followers_of(post, received) do
    case Adapter.forward_to_followers_of_actors(post, received) do
      :relayed_by_group -> {:skip, :relayed_by_group}
      [_ | _] = actors -> {:ok, actors}
      _ -> {:skip, :not_in_our_threads}
    end
  end

  defp inboxes(actors, sender, received) do
    addressed =
      [received["to"], received["cc"], received["bto"], received["bcc"]]
      |> List.flatten()
      |> Enum.map(&Object.get_ap_id/1)
      |> Enum.reject(&(is_nil(&1) or Utils.has_as_public?(&1)))
      |> MapSet.new()

    # an inbox that has it already: the sender's own, and those of whom the author addressed
    delivered =
      addressed
      |> Enum.flat_map(fn id ->
        case Actor.get_cached(ap_id: id) do
          {:ok, actor} -> [actor]
          _ -> []
        end
      end)
      |> then(&[sender | &1])
      |> MapSet.new(&APPublisher.maybe_use_sharedinbox(&1.data))

    actors
    |> Enum.flat_map(&APPublisher.get_external_followers_except(&1, :publish, []))
    |> Enum.reject(
      &(MapSet.member?(addressed, &1.data["id"]) or &1.data["id"] == sender.data["id"])
    )
    |> Enum.map(&APPublisher.maybe_use_sharedinbox(&1.data))
    |> Enum.reject(&(is_nil(&1) or MapSet.member?(delivered, &1)))
    |> Enum.uniq()
    |> debug("inboxes to forward to")
    |> case do
      [] -> {:skip, :nobody_to_forward_to}
      inboxes -> {:ok, inboxes}
    end
  end
end
