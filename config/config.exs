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
  ecto_repos: [ActivityPub.Repo]

# Configures the endpoint
config :activity_pub, ActivityPub.Web.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "sNcPgFlG0+zaRYZF//S3wJC79rLWp63V46ATq6FDCWHYxwHZ7Ece4ScTto64ZSZj",
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

config :activity_pub, :endpoint, ActivityPub.Web.Endpoint

config :activity_pub, ActivityPub.Federator.HTTP.RateLimit,
  scale_ms: String.to_integer(System.get_env("AP_RATELIMIT_PER_MS", "10000")),
  limit: String.to_integer(System.get_env("AP_RATELIMIT_NUM", "20"))

# Imported library config (i.e. the stuff you'd usually put in the config of the app using this library, though of course you can add any of the above in there as well)
import_config "activity_pub.exs"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
