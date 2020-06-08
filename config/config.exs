# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
use Mix.Config

config :activity_pub,
  ecto_repos: [ActivityPub.Repo]

# Configures the endpoint
config :activity_pub, ActivityPubWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "sNcPgFlG0+zaRYZF//S3wJC79rLWp63V46ATq6FDCWHYxwHZ7Ece4ScTto64ZSZj",
  render_errors: [view: ActivityPubWeb.ErrorView, accepts: ~w(json), layout: false],
  pubsub_server: ActivityPub.PubSub,
  live_view: [signing_salt: "cWBjhI3e"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :activity_pub, Oban,
  queues: [federator_incoming: 50, federator_outgoing: 50]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
