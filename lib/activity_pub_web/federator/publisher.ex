# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Federator.Publisher do
  require Logger
  alias ActivityPub.Workers.PublisherWorker

  @moduledoc """
  Defines the contract used by federation implementations to publish messages to
  their peers.
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
  @spec enqueue_one(module(), Map.t()) :: :ok
  def enqueue_one(module, %{} = params) do
    PublisherWorker.enqueue(
      "publish_one",
      %{"module" => to_string(module), "params" => params}
    )
  end

  @doc """
  Relays an activity to all specified peers.
  """
  @callback publish(Map.t(), Map.t()) :: :ok | {:error, any()}

  @spec publish(Map.t(), Map.t()) :: :ok
  def publish(user, activity) do
    Application.get_env(:moodle_net, :instance)[:federation_publisher_modules]
    |> Enum.each(fn module ->
      if module.is_representable?(activity) do
        Logger.info("Publishing #{activity.data["id"]} using #{inspect(module)}")
        module.publish(user, activity)
      end
    end)

    :ok
  end

  @doc """
  Gathers links used by an outgoing federation module for WebFinger output.
  """
  @callback gather_webfinger_links(Map.t()) :: list()

  @spec gather_webfinger_links(Map.t()) :: list()
  def gather_webfinger_links(user) do
    Application.get_env(:moodle_net, :instance)[:federation_publisher_modules]
    |> Enum.reduce([], fn module, links ->
      links ++ module.gather_webfinger_links(user)
    end)
  end
end
