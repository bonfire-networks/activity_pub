defmodule ActivityPub.Federator.Worker.ReceiverRouter do
  @moduledoc """
  Routes incoming ActivityPub docs to the correct receiver worker module/queue.

  ## Examples

      iex> base_url = ActivityPub.Web.base_url()
      iex> params = %{"type" => "Create", "to" => [base_url <> "/users/alice"], "cc" => [], "object" => %{"type" => "Note", "tag" => [%{"type" => "Mention", "href" => base_url <> "/users/alice"}]}}
      iex> ActivityPub.Federator.Worker.ReceiverRouter.route_worker(params, true)
      ActivityPub.Federator.Workers.ReceiverMentionsWorker

      iex> params = %{"type" => "Follow"}
      iex> ActivityPub.Federator.Worker.ReceiverRouter.route_worker(params, true)
      ActivityPub.Federator.Workers.ReceiverFollowsWorker

      iex> params = %{"type" => "Create"}
      iex> ActivityPub.Federator.Worker.ReceiverRouter.route_worker(params, false)
      ActivityPub.Federator.Workers.ReceiverUnverifiedWorker

      iex> params = %{"type" => "Create"}
      iex> ActivityPub.Federator.Worker.ReceiverRouter.route_worker(params, true)
      ActivityPub.Federator.Workers.ReceiverWorker

  """

  alias ActivityPub.Config

  @doc """
  Returns the appropriate receiver worker module for the given AP doc params and signature status.
  """
  def route_worker(params, verified?) do
    cond do
      has_local_mentions_or_private?(params) ->
        ActivityPub.Federator.Workers.ReceiverMentionsWorker

      follow?(params) ->
        ActivityPub.Federator.Workers.ReceiverFollowsWorker

      verified? != true ->
        ActivityPub.Federator.Workers.ReceiverUnverifiedWorker

      true ->
        ActivityPub.Federator.Workers.ReceiverWorker
    end
  end

  @doc """
  Returns true if the AP doc is a local mention or local DM.
  """
  def has_local_mentions_or_private?(%{"type" => "Create", "object" => object} = params) do
    has_local_mentions?(object) or private_for_local_user?(params)
  end

  def has_local_mentions_or_private?(_), do: false

  @doc """
  Returns true if the AP doc is a Follow.
  """
  def follow?(%{"type" => "Follow"}), do: true
  def follow?(_), do: false

  @doc """
  Returns true if the object contains a mention tag for a local user.

      iex> base_url = ActivityPub.Web.base_url()
      iex> ActivityPub.Federator.Worker.ReceiverRouter.has_local_mentions?(%{"tag" => [%{"type" => "Mention", "href" => base_url <> "/users/alice"}]})
      true

      iex> ActivityPub.Federator.Worker.ReceiverRouter.has_local_mentions?(%{"tag" => [%{"type" => "Mention", "href" => "https://remote.site/users/bob"}]})
      false

      iex> ActivityPub.Federator.Worker.ReceiverRouter.has_local_mentions?(%{})
      false
  """
  def has_local_mentions?(%{"tag" => tags}) when is_list(tags) do
    base_url = ActivityPub.Web.base_url()
    base_url_length = String.length(base_url)

    Enum.any?(tags, fn
      %{"type" => "Mention", "href" => <<^base_url::binary-size(base_url_length), _rest::binary>>} ->
        true

      _ ->
        false
    end)
  end

  def has_local_mentions?(_), do: false

  @doc """
  Returns true if the activity is a local direct message (at least one recipient is local and none are public).

      iex> base_url = ActivityPub.Web.base_url()
      iex> ActivityPub.Federator.Worker.ReceiverRouter.private_for_local_user?(%{"to" => [base_url <> "/users/alice"], "cc" => []})
      true

      iex> ActivityPub.Federator.Worker.ReceiverRouter.private_for_local_user?(%{"to" => ["https://remote.site/users/bob"], "cc" => []})
      false

      iex> base_url = ActivityPub.Web.base_url()
      iex> ActivityPub.Federator.Worker.ReceiverRouter.private_for_local_user?(%{"to" => [base_url <> "/users/alice", "https://remote.site/users/bob"], "cc" => []})
      true

      iex> base_url = ActivityPub.Web.base_url()
      iex> ActivityPub.Federator.Worker.ReceiverRouter.private_for_local_user?(%{"to" => [base_url <> "/users/alice"], "cc" => ["https://www.w3.org/ns/activitystreams#Public"]})
      false

      iex> base_url = ActivityPub.Web.base_url()
      iex> ActivityPub.Federator.Worker.ReceiverRouter.private_for_local_user?(%{"to" => ["https://www.w3.org/ns/activitystreams#Public"], "cc" => [base_url <> "/users/alice"]})
      false
  """
  def private_for_local_user?(%{"to" => to, "cc" => cc}) do
    check_private_for_local_user?(List.wrap(to) ++ List.wrap(cc))
  end

  def private_for_local_user?(%{"to" => to}) do
    check_private_for_local_user?(List.wrap(to))
  end

  def private_for_local_user?(%{"cc" => cc}) do
    check_private_for_local_user?(List.wrap(cc))
  end

  def private_for_local_user?(_), do: false

  defp check_private_for_local_user?(recipients) do
    base_url = ActivityPub.Web.base_url()
    base_url_length = String.length(base_url)
    public_uris = Config.public_uris()

    # First, if any recipient is public, halt and return false
    if Enum.any?(recipients, fn url -> url in public_uris end) do
      false
    else
      # Otherwise, check if looks like a DM / private activity where at least one recipient is local
      Enum.any?(recipients, fn
        <<^base_url::binary-size(base_url_length), _rest::binary>> -> true
        _ -> false
      end)
    end
  end
end
