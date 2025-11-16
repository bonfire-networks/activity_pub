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

  @hooks [
    # hook(module: Cachex.Stats),
    Cachex.Spec.hook(
      module: Cachex.Limit.Scheduled,
      args: {
        # setting cache max size
        2_500,
        # options for `Cachex.prune/3`
        [],
        # options for `Cachex.Limit.Scheduled`
        []
      }
    )
  ]

  # NOTE: limit is deprecated in 4.0, replaced by hooks ^
  # @limit Cachex.Spec.limit(
  #          #  max number of entries
  #          size: 2_500,
  #          # the policy to use for eviction
  #          policy: Cachex.Policy.LRW,
  #          # what % to reclaim when limit is reached
  #          reclaim: 0.1
  #        )

  if Mix.env() == :test and Application.compile_env(:activity_pub, :disable_test_apps) != true do
    def start(_type, _args) do
      children =
        [
          rate_limiter(),
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
  else
    def start(_type, _args) do
      children = [rate_limiter()] ++ cachex()

      # See https://hexdocs.pm/elixir/Supervisor.html
      # for other strategies and supported options
      opts = [strategy: :one_for_one, name: ActivityPub.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end

  defp rate_limiter do
    # Read cleanup interval from config (in milliseconds)
    # Default to 10 minutes (600_000 ms) if not specified
    clean_period =
      Application.get_env(:hammer, :backend)
      |> case do
        {_, opts} when is_list(opts) -> Keyword.get(opts, :cleanup_interval_ms, 600_000)
        _ -> 600_000
      end

    {ActivityPub.Web.RateLimit, clean_period: clean_period}
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
                 hooks: @hooks
                 #  limit: @limit
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
                 hooks: @hooks
                 #  limit: @limit
               ]
             ]}
        }
      ],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    ActivityPub.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
