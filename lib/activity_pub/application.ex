defmodule ActivityPub.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @name Mix.Project.config()[:name]
  @version Mix.Project.config()[:version]
  @repository Mix.Project.config()[:source_url]

  def name, do: @name
  def version, do: @version
  def named_version, do: @name <> " " <> @version
  def repository, do: @repository

  def start(_type, _args) do
    children = [
      # Start the Ecto repository
      ActivityPub.Repo,
      # Start the Telemetry supervisor
      ActivityPubWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: ActivityPub.PubSub},
      # Start the Endpoint (http/https)
      ActivityPubWeb.Endpoint,
      # Start a worker by calling: ActivityPub.Worker.start_link(arg)
      # {ActivityPub.Worker, arg}
      {Oban, oban_config()},
      %{
        id: :cachex_actor,
        start:
          {Cachex, :start_link,
           [
             :ap_actor_cache,
             [
               default_ttl: 25_000,
               ttl_interval: 1000,
               limit: 2500
             ]
           ]}
      },
      %{
        id: :cachex_object,
        start:
          {Cachex, :start_link,
           [
             :ap_object_cache,
             [
               default_ttl: 25_000,
               ttl_interval: 1000,
               limit: 2500
             ]
           ]}
      }
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ActivityPub.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp oban_config() do
    opts = Application.get_env(:activity_pub, Oban)

    # Prevent running queues or scheduling jobs from an iex console, i.e. when starting app with `iex -S mix`
    if Code.ensure_loaded?(IEx) and IEx.started?() do
      opts
      |> Keyword.put(:crontab, false)
      |> Keyword.put(:queues, false)
    else
      opts
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    ActivityPubWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
