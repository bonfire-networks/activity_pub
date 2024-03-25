# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :activity_pub,
  env: Mix.env(),
  repo: ActivityPub.Repo,
  ecto_repos: [ActivityPub.Repo],
  sign_object_fetches: true

# Configures the endpoint
config :activity_pub, ActivityPub.Web.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "sNcPgFlG0+zaRYZF//S3wJC79rLWp63V46ATq6FDCWHYxwHZ7Ece4ScTto64ZSZj",
  render_errors: [
    view: ActivityPub.Web.ErrorView,
    accepts: ~w(json),
    layout: false
  ],
  pubsub_server: ActivityPub.PubSub,
  live_view: [signing_salt: "cWBjhI3e"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :mime, :types, %{
  "application/json" => ["json"],
  "application/activity+json" => ["activity+json"],
  "application/ld+json" => ["ld+json"],
  "application/jrd+json" => ["jrd+json"]
}

config :activity_pub, Oban,
  queues: [federator_incoming: 50, federator_outgoing: 50, remote_fetcher: 20],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"@daily", ActivityPub.Pruner.PruneDatabaseWorker}
     ]}
  ]

config :activity_pub, :oban_queues,
  retries: [federator_incoming: 2, federator_outgoing: 3, remote_fetcher: 1]

config :activity_pub, :mrf_simple,
  media_removal: [],
  media_nsfw: [],
  report_removal: [],
  accept: [],
  avatar_removal: [],
  banner_removal: []

config :activity_pub, :instance,
  hostname: "localhost",
  federation_publisher_modules: [ActivityPub.Federator.APPublisher],
  federation_reachability_timeout_days: 7,
  # Max. depth of reply-to and reply activities fetching on incoming federation, to prevent out-of-memory situations while fetching very long threads.
  federation_incoming_max_recursion: 10,
  rewrite_policy: [],
  handle_unknown_activities: false

config :activity_pub, :http,
  proxy_url: nil,
  user_agent: "ActivityPub Elixir library",
  send_user_agent: true,
  adapter: [
    ssl_options: [
      # Workaround for remote server certificate chain issues
      partial_chain: &:hackney_connect.partial_chain/1,
      # We don't support TLS v1.3 yet
      versions: [:tlsv1, :"tlsv1.1", :"tlsv1.2"]
    ]
  ]

config :activity_pub, :endpoint, ActivityPub.Web.Endpoint

config :activity_pub, ActivityPub.Federator.HTTP.RateLimit,
  scale_ms: String.to_integer(System.get_env("AP_RATELIMIT_PER_MS", "10000")),
  limit: String.to_integer(System.get_env("AP_RATELIMIT_NUM", "20"))

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 4, cleanup_interval_ms: 60_000 * 10]}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
