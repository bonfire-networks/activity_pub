defmodule ActivityPub.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Cachex.Spec

  @name Mix.Project.config()[:name]
  @version Mix.Project.config()[:version]
  @repository Mix.Project.config()[:source_url]

  def name, do: @name
  def version, do: @version
  def named_version, do: @name <> " " <> @version
  def repository, do: @repository

  def repo,
    do: Application.get_env(:activity_pub, :repo, ActivityPub.TestRepo)

  @expiration Cachex.Spec.expiration(
                #  42 minutes by default
                default: 2_520_000,
                interval: 1000
              )

  @limit Cachex.Spec.limit(
           #  max number of entries
           size: 2_500,
           # the policy to use for eviction
           policy: Cachex.Policy.LRW,
           # what % to reclaim when limit is reached
           reclaim: 0.1
         )

  if Mix.env() == :test and Application.compile_env(:activity_pub, :disable_test_apps) != true do
    def start(_type, _args) do
      children =
        [
          # Start the Ecto repository
          repo(),
          # Start the Telemetry supervisor
          ActivityPub.Web.Telemetry,
          # Start the PubSub system
          {Phoenix.PubSub, name: ActivityPub.PubSub},
          # Start the Endpoint (http/https)
          ActivityPub.Web.Endpoint,
          # Start a worker by calling: ActivityPub.Worker.start_link(arg)
          # {ActivityPub.Worker, arg}
          {Oban, oban_config()}
        ] ++ cachex()

      # See https://hexdocs.pm/elixir/Supervisor.html
      # for other strategies and supported options
      opts = [strategy: :one_for_one, name: ActivityPub.Supervisor]
      Supervisor.start_link(children, opts)
    end
  else
    def start(_type, _args) do
      children = cachex()

      # See https://hexdocs.pm/elixir/Supervisor.html
      # for other strategies and supported options
      opts = [strategy: :one_for_one, name: ActivityPub.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end

  def cachex() do
    if Application.get_env(:activity_pub, :disable_cache) != true,
      do: [
        %{
          id: :ap_actor_cache,
          start:
            {Cachex, :start_link,
             [
               :ap_actor_cache,
               [
                 expiration: @expiration,
                 limit: @limit
               ]
             ]}
        },
        %{
          id: :ap_object_cache,
          start:
            {Cachex, :start_link,
             [
               :ap_object_cache,
               [
                 expiration: @expiration,
                 limit: @limit
               ]
             ]}
        }
      ],
      else: []
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
    ActivityPub.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
