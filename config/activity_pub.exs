import Config

config :activity_pub,
  sign_object_fetches: true,
  reject_unsigned: true,
  env: config_env(),
  # FEP-844e: capabilities advertised via actor generator.implements
  implements: [
    "https://www.w3.org/TR/activitypub/",
    "https://datatracker.ietf.org/doc/html/rfc9421"
  ]

#   adapter: MyApp.Adapter,
#   repo: MyApp.Repo

# config :nodeinfo, :adapter, MyApp.NodeinfoAdapter

config :activity_pub, :instance,
  hostname: "localhost",
  federation_publisher_modules: [ActivityPub.Federator.APPublisher],
  federation_reachability_timeout_days: 7,
  # Max. depth of reply-to and reply activities fetching on incoming federation, to prevent out-of-memory situations while fetching very long threads.
  federation_incoming_max_recursion: 10,
  #   rewrite_policy: [MyApp.MRF],
  handle_unknown_activities: true

config :activity_pub, :boundaries,
  block: [],
  silence_them: [],
  ghost_them: []

config :activity_pub, :mrf_simple,
  reject: [],
  accept: [],
  media_removal: [],
  media_nsfw: [],
  report_removal: [],
  avatar_removal: [],
  banner_removal: []

config :http_signatures, adapter: ActivityPub.Safety.HTTP.Signatures

config :activity_pub, :http,
  proxy_url: nil,
  user_agent: "ActivityPub federation library",
  send_user_agent: true,
  adapter: [
    ssl_options: [
      # Workaround for remote server certificate chain issues
      # partial_chain: &:hackney_connect.partial_chain/1,
      # We don't support TLS v1.3 yet
      versions: [:tlsv1, :"tlsv1.1", :"tlsv1.2"]
    ]
  ]

config :activity_pub, ActivityPub.Web.Endpoint,
  render_errors: [
    view: ActivityPub.Web.ErrorView,
    accepts: ~w(json),
    layout: false
  ]

config :activity_pub,
  json_contexts: %{
    "Accept" => %{
      "QuoteRequest" => "https://w3id.org/fep/044f#QuoteRequest"
    },
    "QuoteRequest" => %{
      "QuoteRequest" => "https://w3id.org/fep/044f#QuoteRequest",
      "quote" => %{
        "@id" => "https://w3id.org/fep/044f#quote",
        "@type" => "@id"
      }
    },
    "QuoteAuthorization" => %{
      "QuoteAuthorization" => "https://w3id.org/fep/044f#QuoteAuthorization",
      "gts" => "https://gotosocial.org/ns#",
      "interactingObject" => %{
        "@id" => "gts:interactingObject",
        "@type" => "@id"
      },
      "interactionTarget" => %{
        "@id" => "gts:interactionTarget",
        "@type" => "@id"
      }
    },
    actor: %{
      # TODO: expose Aliases in these fields
      "movedTo" => "as:movedTo",
      "alsoKnownAs" => %{
        "@id" => "as:alsoKnownAs",
        "@type" => "@id"
      },
      "sensitive" => "as:sensitive",
      # TODO
      "manuallyApprovesFollowers" => "as:manuallyApprovesFollowers",
      # FEP-844e: capability discovery
      "implements" => %{
        "@id" => "https://w3id.org/fep/844e#implements",
        "@type" => "@id",
        "@container" => "@set"
      }
    },
    object: %{
      "Hashtag" => "as:Hashtag",
      "sensitive" => "as:sensitive",
      # "conversation": "ostatus:conversation", # TODO?
      "ValueFlows" => "https://w3id.org/valueflows#",
      "om2" => "http://www.ontology-of-units-of-measure.org/resource/om-2/",
      "quote" => %{
        "@id" => "https://w3id.org/fep/044f#quote",
        "@type" => "@id"
      },
      "_misskey_quote" => "https://misskey-hub.net/ns/#_misskey_quote",
      "quoteAuthorization" => %{
        "@id" => "https://w3id.org/fep/044f#quoteAuthorization",
        "@type" => "@id"
      }
    }
  }

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

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 4, cleanup_interval_ms: 60_000 * 10]}
