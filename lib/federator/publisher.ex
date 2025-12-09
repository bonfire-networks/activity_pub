# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Publisher do
  import Untangle
  alias ActivityPub.Federator.Workers.PublisherWorker

  @moduledoc """
  Defines the contract used by federation implementations to publish messages to
  their peers.
  # TODO: why not use `APPublisher` directly instead?
  """

  @doc """
  Determine whether an activity can be relayed using the federation module.
  """
  @callback is_representable?(Map.t()) :: boolean()

  @doc """
  Relays an activity to a specified peer, determined by the parameters.  The
  parameters used are controlled by the federation module.
  """
  @callback publish_one(Map.t()) :: {:ok, Map.t()} | {:error, any()}

  @doc """
  Enqueue publishing a single activity.
  """
  def enqueue_one(module, actor, %{} = params) do
    PublisherWorker.enqueue(
      "publish_one",
      %{
        "module" => to_string(module),
        "params" => params,
        "user_id" => Map.get(actor, :pointer_id) || Map.get(actor, :id)
      },
      PublisherWorker.maybe_schedule_worker_args(params, [])
    )
  end

  @doc """
  Relays an activity to all specified peers.
  """
  @callback publish(Map.t(), Map.t()) :: :ok | {:error, any()}

  @spec publish(Map.t(), Map.t()) :: :ok
  def publish(user, activity) do
    (Application.get_env(:activity_pub, :instance)[
       :federation_publisher_modules
     ] ||
       [ActivityPub.Federator.APPublisher])
    |> Enum.each(fn module ->
      if module.is_representable?(activity) do
        info("Publishing #{activity.data["id"]} using #{inspect(module)}")
        module.publish(user, activity)
      else
        {:error, "activity is not representable"}
      end
    end)

    # :ok
  end

  @doc """
  Gathers links used by an outgoing federation module for WebFinger output.
  """
  @callback gather_webfinger_links(Map.t()) :: list()

  @spec gather_webfinger_links(Map.t()) :: list()
  def gather_webfinger_links(id) do
    (Application.get_env(:activity_pub, :instance, [])[:federation_publisher_modules] ||
       [ActivityPub.Federator.APPublisher])
    |> Enum.reduce([], fn module, links ->
      links ++ module.gather_webfinger_links(id)
    end)
  end
end
