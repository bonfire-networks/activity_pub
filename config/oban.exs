# NOTE: you'll probably want to put these in your runtime config instead:
config :activity_pub, Oban,
  queues: [
    federator_incoming_mentions:
      String.to_integer(System.get_env("QUEUE_SIZE_AP_IN_MENTIONS", "2")),
    federator_incoming: String.to_integer(System.get_env("QUEUE_SIZE_AP_IN", "3")),
    federator_incoming_follows:
      String.to_integer(System.get_env("QUEUE_SIZE_AP_IN_FOLLOWS", "2")),
    federator_incoming_unverified:
      String.to_integer(System.get_env("QUEUE_SIZE_AP_IN_UNVERIFIED", "1")),
    federator_outgoing: String.to_integer(System.get_env("QUEUE_SIZE_AP_OUT", "2")),
    remote_fetcher: String.to_integer(System.get_env("QUEUE_SIZE_AP_FETCH", "1")),
    import: String.to_integer(System.get_env("QUEUE_SIZE_IMPORT", "1")),
    deletion: String.to_integer(System.get_env("QUEUE_SIZE_DELETION", "1")),
    database_prune: String.to_integer(System.get_env("QUEUE_SIZE_DB_PRUNE", "1")),
    static_generator: String.to_integer(System.get_env("QUEUE_SIZE_STATIC_GEN", "1")),
    # video_transcode: 1,
    # boost_activities: 1,
    fetch_open_science: String.to_integer(System.get_env("QUEUE_SIZE_OPEN_SCIENCE_FETCH", "1"))
  ],
  plugins: [
    # delete job history after 7 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # rescue orphaned jobs
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}
  ]

config :activity_pub, :oban_queues,
  retries: [federator_incoming: 2, federator_outgoing: 3, remote_fetcher: 1]

config :activity_pub, ActivityPub.Federator.HTTP.RateLimit,
  scale_ms: String.to_integer(System.get_env("AP_RATELIMIT_PER_MS", "10000")),
  limit: String.to_integer(System.get_env("AP_RATELIMIT_NUM", "20"))
