# Rules for Working with ActivityPub Library

## Core Principles

- **Always implement all required adapter callbacks** - Missing callbacks will cause runtime errors
- **Never trust remote data** - Always validate and sanitize incoming activities
- **Respect federation boundaries** - Check `federate_actor?` before any federation operation
- **Handle failures gracefully** - Federation is unreliable by nature
- **Cache aggressively but invalidate properly** - Performance depends on good caching
- **Sign all requests** - HTTP signatures are mandatory for security

## Adapter Implementation

**Always implement the full `ActivityPub.Federator.Adapter` behaviour**. Missing any required callback will cause federation to fail.

### Required Adapter Structure

```elixir
defmodule MyApp.ActivityPubAdapter do
  @behaviour ActivityPub.Federator.Adapter

  # REQUIRED - All callbacks must be implemented
  @impl true
  def base_url, do: "https://myapp.example.com"
  
  @impl true
  def get_actor_by_id(id), do: # implementation
  
  @impl true
  def get_actor_by_username(username), do: # implementation
  
  @impl true
  def get_actor_by_ap_id(ap_id), do: # implementation
  
  # ... all other required callbacks
end
```

### Actor Retrieval Guidelines

**Always return actors in the correct format**:

```elixir
# GOOD - Returns proper Actor struct
def get_actor_by_username(username) do
  case MyApp.Users.get_by_username(username) do
    nil -> {:error, :not_found}
    user -> {:ok, user_to_actor(user)}
  end
end

# BAD - Returns raw user struct
def get_actor_by_username(username) do
  {:ok, MyApp.Users.get_by_username(username)}
end
```

**Always validate actor format**:

```elixir
# GOOD - Proper Actor struct with all required fields
%ActivityPub.Actor{
  id: user.id,  # Internal ID
  data: %{
    "id" => "https://myapp.com/users/#{username}",  # AP ID
    "type" => "Person",
    "preferredUsername" => username,
    "inbox" => "https://myapp.com/users/#{username}/inbox",
    "outbox" => "https://myapp.com/users/#{username}/outbox",
    "followers" => "https://myapp.com/users/#{username}/followers",
    "following" => "https://myapp.com/users/#{username}/following"
  },
  local: true,
  keys: pem_keys,  # Required for local actors
  ap_id: "https://myapp.com/users/#{username}",
  username: username,
  pointer_id: user.id
}

# BAD - Missing required AP endpoints
%ActivityPub.Actor{
  id: user.id,
  data: %{"id" => "https://myapp.com/users/#{username}"},
  local: true
}
```

### Activity Handling Rules

**Always validate incoming activities in your adapter**:

```elixir
# GOOD - Validate before processing
def handle_activity(%{data: %{"type" => "Create", "object" => object}} = activity) do
  with :ok <- validate_object(object),
       :ok <- check_spam(object),
       {:ok, local_object} <- create_from_ap(object) do
    {:ok, local_object}
  else
    {:error, reason} -> {:error, reason}
  end
end

# BAD - No validation
def handle_activity(%{data: %{"type" => "Create", "object" => object}}) do
  create_from_ap(object)
end
```

**Never process activities from blocked actors**:

```elixir
# GOOD - Check blocks first
def handle_activity(activity) do
  actor_id = activity.data["actor"]
  
  if blocked?(actor_id) do
    {:error, :blocked}
  else
    process_activity(activity)
  end
end
```

### Federation Control

**Always implement `federate_actor?` to control federation boundaries**:

```elixir
# GOOD - Check both directions and blocks
def federate_actor?(actor, direction, by_actor) do
  case direction do
    :in ->
      # Check if we accept activities from this actor
      not blocked?(actor) and not instance_blocked?(actor)
    
    :out ->
      # Check if we send activities to this actor
      actor.local and not actor.private and not blocked?(by_actor)
    
    _ ->
      # Both directions
      not blocked?(actor) and not blocked?(by_actor)
  end
end

# BAD - No boundary checking
def federate_actor?(_actor, _direction, _by_actor) do
  true
end
```

### Publishing Objects

**Always convert your objects to proper ActivityStreams format**:

```elixir
# GOOD - Complete AP object
def maybe_publish_object(post_id, _manually_fetching?) do
  post = MyApp.Posts.get!(post_id)
  
  {:ok, %ActivityPub.Object{
    data: %{
      "id" => "https://myapp.com/posts/#{post.id}",
      "type" => "Note",
      "content" => post.content,
      "attributedTo" => "https://myapp.com/users/#{post.author.username}",
      "published" => DateTime.to_iso8601(post.inserted_at),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => ["https://myapp.com/users/#{post.author.username}/followers"]
    },
    local: true,
    public: true
  }}
end

# BAD - Incomplete object
def maybe_publish_object(post_id, _) do
  post = MyApp.Posts.get!(post_id)
  {:ok, %{content: post.content}}
end
```

## Activity Creation Guidelines

### Creating Activities

**Always include proper addressing for activities**:

```elixir
# GOOD - Complete addressing
ActivityPub.create(%{
  to: ["https://www.w3.org/ns/activitystreams#Public"],
  cc: [actor.data["followers"]],
  actor: actor,
  context: context_id,
  object: %{
    "type" => "Note",
    "content" => "Hello, Fediverse!",
    "to" => ["https://www.w3.org/ns/activitystreams#Public"],
    "cc" => [actor.data["followers"]]
  },
  local: true
})

# BAD - Missing addressing
ActivityPub.create(%{
  actor: actor,
  object: %{"type" => "Note", "content" => "Hello!"},
  local: true
})
```

**Never create activities for remote actors**:

```elixir
# WRONG - Creating activity for remote actor
remote_actor = ActivityPub.Actor.get_cached!(ap_id: "https://remote.com/users/bob")
ActivityPub.create(%{actor: remote_actor, ...})  # This will fail!

# CORRECT - Only create for local actors
local_actor = Adapter.get_actor_by_username("alice")
ActivityPub.create(%{actor: local_actor, ...})
```

### Following Guidelines

**Always check if follow is allowed before creating**:

```elixir
# GOOD - Check boundaries first
def follow_user(follower, followed) do
  if Adapter.federate_actor?(followed, :in, follower) do
    ActivityPub.follow(%{
      actor: follower,
      object: followed,
      local: true
    })
  else
    {:error, :not_allowed}
  end
end

# BAD - No permission check
def follow_user(follower, followed) do
  ActivityPub.follow(%{actor: follower, object: followed, local: true})
end
```

## Actor Management

### Fetching Actors

**Prefer cached operations to avoid unnecessary network requests**:

```elixir
# GOOD - Try cache first
case ActivityPub.Actor.get_cached(ap_id: ap_id) do
  {:ok, actor} -> {:ok, actor}
  _ -> ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)
end

# WASTEFUL - Always fetches
ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)
```

**Always handle fetch failures**:

```elixir
# GOOD - Handle errors
case ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id) do
  {:ok, actor} -> process_actor(actor)
  {:error, :unreachable} -> handle_unreachable_instance()
  {:error, reason} -> log_error(reason)
end

# BAD - Assumes success
{:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)
```

### Key Management

**Never expose private keys**:

```elixir
# GOOD - Only include keys for local actors
def actor_json(actor) do
  data = %{
    "id" => actor.ap_id,
    "publicKey" => %{
      "id" => "#{actor.ap_id}#main-key",
      "owner" => actor.ap_id,
      "publicKeyPem" => get_public_key(actor)  # Only public key
    }
  }
end

# BAD - Exposing private keys
def actor_json(actor) do
  %{
    "publicKey" => actor.keys  # Never expose raw keys!
  }
end
```

## Security Guidelines

### HTTP Signature Validation

**Always verify signatures on incoming activities**:

```elixir
# GOOD - Signature verification is mandatory
# This is handled automatically by the library, but ensure your routes use:
pipeline :activity_pub do
  plug ActivityPub.Web.Plugs.FetchHTTPSignaturePlug
  plug ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug
end

# BAD - Bypassing signature verification
# Never accept unsigned ActivityPub requests!
```

**Never accept activities where actor doesn't match signature**:

```elixir
# The library handles this, but in your adapter:
# GOOD - Verify actor matches
def handle_activity(%{data: %{"actor" => actor}} = activity) do
  if actor == activity.actor.ap_id do
    process_activity(activity)
  else
    {:error, :actor_mismatch}
  end
end
```

### MRF Configuration

**Always configure MRF policies for safety**:

```elixir
# GOOD - Basic safety configuration
config :activity_pub, :instance,
  rewrite_policy: [
    ActivityPub.MRF.SimplePolicy,
    MyApp.CustomMRFPolicy
  ]

config :activity_pub, :mrf_simple,
  reject: ["known-bad.example.com"],
  media_removal: ["nsfw.example.com"],
  report_removal: ["spam.example.com"]

# BAD - No MRF policies
config :activity_pub, :instance,
  rewrite_policy: []
```

### Instance Management

**Always handle unreachable instances gracefully**:

```elixir
# GOOD - Check reachability
def fetch_remote_user(ap_id) do
  case ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id) do
    {:ok, actor} -> 
      {:ok, actor}
    {:error, :unreachable} ->
      # Instance is down, use cached data if available
      ActivityPub.Actor.get_cached(ap_id: ap_id)
    error ->
      error
  end
end

# BAD - No error handling for unreachable instances
def fetch_remote_user(ap_id) do
  ActivityPub.Actor.get_cached_or_fetch!(ap_id: ap_id)
end
```

## Common Federation Mistakes

### Addressing Mistakes

**Never use string concatenation for public URI**:

```elixir
# WRONG - Typos will break federation
to: ["https://www.w3.org/ns/activitystreams#public"]  # lowercase!

# CORRECT - Use the constant
to: ["https://www.w3.org/ns/activitystreams#Public"]

# BETTER - Use a helper
def public_uri, do: "https://www.w3.org/ns/activitystreams#Public"
```

### Object ID Mistakes

**Always use full URLs for object IDs**:

```elixir
# WRONG - Relative IDs break federation
%{
  "id" => "/posts/123",
  "type" => "Note"
}

# CORRECT - Full URL
%{
  "id" => "https://myapp.com/posts/123",
  "type" => "Note"
}
```

### Context Threading

**Always preserve context for replies**:

```elixir
# GOOD - Preserve thread context
def create_reply(parent, content) do
  context = parent.data["context"] || parent.data["conversation"] || parent.data["id"]
  
  ActivityPub.create(%{
    object: %{
      "type" => "Note",
      "content" => content,
      "inReplyTo" => parent.data["id"],
      "context" => context  # Important!
    }
  })
end

# BAD - Lost threading
def create_reply(parent, content) do
  ActivityPub.create(%{
    object: %{
      "type" => "Note",
      "content" => content,
      "inReplyTo" => parent.data["id"]
      # Missing context!
    }
  })
end
```

## Configuration Guidelines

### Required Configuration

**Always configure the minimum required settings**:

```elixir
# GOOD - Complete required configuration
config :activity_pub, :adapter, MyApp.ActivityPubAdapter
config :activity_pub, :repo, MyApp.Repo
config :activity_pub, :instance,
  hostname: "myapp.example.com",
  federating: true

# BAD - Missing required configuration
config :activity_pub, :adapter, MyApp.ActivityPubAdapter
# Missing repo and instance config will cause runtime errors!
```

**Never use localhost or example.com in production**:

```elixir
# WRONG - Invalid hostnames
config :activity_pub, :instance,
  hostname: "localhost"  # Will break federation!

# CORRECT - Valid public hostname
config :activity_pub, :instance,
  hostname: "myapp.example.com"
```

### Security Configuration

**Always sign object fetches for better security**:

```elixir
# GOOD - Signed fetches
config :activity_pub, :sign_object_fetches, true

# RISKY - Unsigned fetches
config :activity_pub, :sign_object_fetches, false
```

**Always set reasonable federation limits**:

```elixir
# GOOD - Protect against recursion attacks
config :activity_pub, :instance,
  federation_incoming_max_recursion: 10,
  federation_incoming_max_items: 5

# BAD - No limits (DoS risk)
config :activity_pub, :instance,
  federation_incoming_max_recursion: 1000,
  federation_incoming_max_items: 1000
```

### HTTP Configuration

**Always set a descriptive user agent**:

```elixir
# GOOD - Identifies your instance
config :activity_pub, :http,
  user_agent: "MyApp/1.0 (+https://myapp.com)",
  send_user_agent: true

# BAD - Generic or missing user agent
config :activity_pub, :http,
  send_user_agent: false
```

**Use proxy configuration when behind a proxy**:

```elixir
# GOOD - Proxy aware
config :activity_pub, :http,
  proxy_url: "http://proxy.internal:8080"

# BAD - Ignoring proxy requirements
# Will fail to connect if behind mandatory proxy
```

## Common Patterns

### Handling Incoming Activities

**Always validate and handle errors in your adapter's `handle_activity/1`**:

```elixir
# GOOD - Complete validation and error handling
def handle_activity(%{data: %{"type" => "Create", "object" => object}} = activity) do
  with :ok <- validate_create_activity(activity),
       {:ok, local_object} <- create_from_ap(object),
       {:ok, _} <- notify_users(local_object) do
    {:ok, local_object}
  else
    {:error, :invalid_object} -> {:error, "Invalid object format"}
    {:error, reason} -> {:error, reason}
  end
end

# BAD - No validation or error handling
def handle_activity(%{data: %{"type" => "Create", "object" => object}}) do
  local_object = create_from_ap!(object)
  notify_users!(local_object)
  {:ok, local_object}
end
```

**Always handle all activity types you support**:

```elixir
# GOOD - Handle supported types, reject unknown
def handle_activity(%{data: %{"type" => type}} = activity) do
  case type do
    "Create" -> handle_create(activity)
    "Update" -> handle_update(activity)
    "Delete" -> handle_delete(activity)
    "Follow" -> handle_follow(activity)
    "Like" -> handle_like(activity)
    "Announce" -> handle_announce(activity)
    _ -> {:error, "Unsupported activity type: #{type}"}
  end
end

# BAD - Silent failures for unknown types
def handle_activity(activity) do
  # Only handles some types, ignores others
  handle_create(activity)
end
```

### Publishing Local Content

**Always federate after successful local creation**:

```elixir
# GOOD - Create locally first, then federate
def create_post(author, attrs) do
  with {:ok, post} <- Posts.create(author, attrs),
       {:ok, actor} <- get_actor_for_user(author),
       {:ok, activity} <- ActivityPub.create(%{
         actor: actor,
         to: ["https://www.w3.org/ns/activitystreams#Public"],
         object: post_to_ap_object(post),
         local: true
       }) do
    {:ok, post}
  else
    {:error, reason} -> 
      # Local creation failed, don't federate
      {:error, reason}
  end
end

# BAD - Federation before local persistence
def create_post(author, attrs) do
  {:ok, activity} = ActivityPub.create(%{...})  # Federates first!
  Posts.create(author, attrs)  # Might fail after federation
end
```

### Implementing Federation Controls

**Always implement granular federation controls**:

```elixir
# GOOD - Direction-aware controls
def federate_actor?(actor, direction, by_actor) do
  case direction do
    :in ->
      # Incoming: Check blocks and instance policies
      not actor_blocked?(actor) and 
      not instance_blocked?(actor) and
      accepting_activities?()
    
    :out ->
      # Outgoing: Check privacy settings
      actor.local and 
      not actor.private and
      federating_enabled?(by_actor)
  end
end

# BAD - No direction awareness
def federate_actor?(_actor, _direction, _by_actor) do
  true  # Federates everything!
end
```

## Testing Guidelines

### Mock Adapter Rules

**Always create a complete mock adapter for tests**:

```elixir
# GOOD - Complete mock implementation
defmodule MyApp.MockAdapter do
  @behaviour ActivityPub.Federator.Adapter
  
  def base_url, do: "https://test.example.com"
  def get_actor_by_id(id), do: {:ok, mock_actor(id)}
  def get_actor_by_username(username), do: {:ok, mock_actor(username)}
  def get_actor_by_ap_id(ap_id), do: {:ok, mock_actor(ap_id)}
  def handle_activity(activity), do: {:ok, activity}
  def maybe_publish_object(id, _), do: {:ok, mock_object(id)}
  # ... implement ALL required callbacks
end

# BAD - Partial implementation
defmodule MyApp.BadMockAdapter do
  @behaviour ActivityPub.Federator.Adapter
  def base_url, do: "https://test.example.com"
  # Missing required callbacks!
end
```

**Never use production adapter in tests**:

```elixir
# WRONG - Tests will hit real federation
config :activity_pub, :adapter, MyApp.ProductionAdapter

# CORRECT - Use mock for isolation
config :activity_pub, :adapter, MyApp.MockAdapter
```

### HTTP Mocking Rules

**Always mock external HTTP requests in tests**:

```elixir
# GOOD - Predictable test responses
setup do
  Tesla.Mock.mock(fn
    %{url: "https://remote.example/actor"} ->
      %Tesla.Env{status: 200, body: valid_actor_json()}
    %{url: "https://remote.example/inbox"} ->
      %Tesla.Env{status: 202, body: ""}
    _ ->
      %Tesla.Env{status: 404, body: "Not Found"}
  end)
  :ok
end

# BAD - No mocking, tests make real requests
test "fetch remote actor" do
  # This will make actual HTTP requests!
  {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: "https://real.site/user")
end
```

### Test Data Rules

**Always use valid ActivityStreams format in tests**:

```elixir
# GOOD - Valid AS2 data
def valid_actor_json do
  %{
    "@context" => "https://www.w3.org/ns/activitystreams",
    "id" => "https://remote.example/actor",
    "type" => "Person",
    "inbox" => "https://remote.example/actor/inbox",
    "outbox" => "https://remote.example/actor/outbox",
    "preferredUsername" => "testuser"
  }
end

# BAD - Invalid/incomplete data
def bad_actor_json do
  %{"name" => "Test User"}  # Missing required fields!
end
```

## Performance Guidelines

### Caching Rules

**Always use caching for remote actors and objects**:

```elixir
# GOOD - Use cached operations
ActivityPub.Actor.get_cached(ap_id: ap_id) || 
  ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)

# BAD - Always fetching
ActivityPub.Actor.get_or_fetch(ap_id: ap_id, force: true)
```

**Never cache local actors longer than remote actors**:

```elixir
# Configuration should reflect this
config :activity_pub, :cache,
  remote_actor_ttl: :timer.hours(24),
  local_actor_ttl: :timer.hours(1)  # Shorter for local
```

### Background Job Rules

**Always process federation in background jobs**:

```elixir
# GOOD - Queue for background processing
def publish_activity(activity) do
  Oban.insert(FederationWorker.new(%{activity_id: activity.id}))
end

# BAD - Synchronous federation
def publish_activity(activity) do
  Enum.each(recipients, fn inbox ->
    HTTPClient.post(inbox, activity)  # Blocks!
  end)
end
```

### Delivery Optimization

**Always batch deliveries to the same instance**:

```elixir
# GOOD - Group by instance
def deliver_to_inboxes(activity, inboxes) do
  inboxes
  |> Enum.group_by(&URI.parse(&1).host)
  |> Enum.map(fn {_host, inbox_list} ->
    # Deliver to shared inbox if available
    deliver_to_instance(activity, inbox_list)
  end)
end

# BAD - Individual delivery to each inbox
def deliver_to_inboxes(activity, inboxes) do
  Enum.each(inboxes, &deliver(activity, &1))
end
```

## Debugging Guidelines

### Logging Rules

**Always enable debug logging when troubleshooting federation**:

```elixir
# GOOD - Verbose logging for debugging
config :activity_pub, :debug, true
config :logger, :console, level: :debug

# Also log specific modules
config :logger, :console,
  metadata: [:module, :actor_id, :activity_id]
```

**Never leave debug logging on in production**:

```elixir
# Production config
config :activity_pub, :debug, false
config :logger, level: :info
```

### Queue Inspection

**Always check job queues when federation seems stuck**:

```elixir
# GOOD - Comprehensive queue check
def inspect_federation_queues do
  Oban.Job
  |> where([j], j.queue in ["federation", "federator_outgoing", "federator_incoming"])
  |> where([j], j.state in ["available", "scheduled", "executing", "retryable"])
  |> Repo.all()
  |> Enum.group_by(& {&1.queue, &1.state})
  |> Enum.map(fn {{queue, state}, jobs} ->
    %{
      queue: queue,
      state: state,
      count: length(jobs),
      oldest: List.first(jobs)
    }
  end)
end

# BAD - Incomplete queue check
Oban.Job |> Repo.all()  # Too much data, not filtered
```

### Activity Inspection

**Always trace activities through the full pipeline**:

```elixir
# GOOD - Complete activity trace
def trace_activity(activity_id) do
  with {:ok, activity} <- ActivityPub.Object.get_by_id(activity_id),
       deliveries <- get_delivery_records(activity),
       jobs <- get_related_jobs(activity) do
    %{
      activity: activity,
      deliveries: deliveries,
      jobs: jobs,
      errors: get_delivery_errors(activity)
    }
  end
end
```

## Common Pitfalls and Solutions

### Routing Pitfalls

**Always add ActivityPub routes to your router**:

```elixir
# GOOD - ActivityPub routes included
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  use ActivityPub.Web.Router  # Required!
  
  # Your other routes...
end

# BAD - Missing AP routes
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  # Federation endpoints won't work!
end
```

### Signature Pitfalls

**Always sign fetches when configured**:

```elixir
# GOOD - Honor signature configuration
if ActivityPub.Config.get(:sign_object_fetches) do
  fetch_with_signature(url, actor)
else
  fetch_without_signature(url)
end

# BAD - Never signing fetches
HTTPClient.get(url)  # Some instances will reject!
```

### Key Generation Pitfalls

**Always generate keys before first federation**:

```elixir
# GOOD - Ensure keys exist
def ensure_actor_keys(actor) do
  if actor.keys do
    {:ok, actor}
  else
    {:ok, keys} = ActivityPub.Safety.Keys.generate_rsa_pem()
    update_actor(actor, %{keys: keys})
  end
end

# BAD - Publishing without keys
ActivityPub.create(%{actor: keyless_actor, ...})  # Will fail!
```

### ID Uniqueness Pitfalls

**Always ensure pointer IDs are unique**:

```elixir
# GOOD - Type-specific IDs
def generate_pointer_id(type, local_id) do
  "#{type}:#{local_id}"  # e.g., "actor:123", "object:456"
end

# BAD - Reusing IDs across types
def generate_pointer_id(_type, local_id) do
  local_id  # Collision risk!
end
```

## Extension Points

### Custom Activity Types

**Always register custom activity types in configuration**:

```elixir
# GOOD - Explicitly declare supported types
config :activity_pub, :instance,
  supported_activity_types: [
    # Standard types
    "Create", "Update", "Delete", "Follow", "Like", "Announce",
    # Custom types
    "Question", "Answer", "Event"
  ]

# BAD - Undeclared custom types
# Using custom types without configuration
ActivityPub.create(%{type: "CustomType", ...})  # Not registered!
```

### Custom MRF Policies

**Always validate in MRF policies, never modify without reason**:

```elixir
# GOOD - Clear policy with validation
defmodule MyApp.SpamFilterMRF do
  @behaviour ActivityPub.MRF
  
  @impl true
  def filter(%{data: %{"content" => content}} = object, local?) do
    if spam?(content) do
      {:reject, "Content identified as spam"}
    else
      {:ok, object}
    end
  end
  
  def filter(object, _local?), do: {:ok, object}
  
  defp spam?(content) do
    # Actual spam detection logic
    String.contains?(content, ~w[spam viagra])
  end
end

# BAD - Modifying without clear reason
defmodule MyApp.BadMRF do
  @behaviour ActivityPub.MRF
  
  @impl true  
  def filter(object, _local?) do
    # Arbitrarily modifying content!
    modified = put_in(object, ["data", "content"], "MODIFIED")
    {:ok, modified}
  end
end
```

**Always add MRF policies to configuration**:

```elixir
# GOOD - Policy registered
config :activity_pub, :instance,
  rewrite_policy: [
    ActivityPub.MRF.SimplePolicy,
    MyApp.SpamFilterMRF,
    MyApp.CustomMRF
  ]

# BAD - Policy not in config
# MRF policy exists but isn't configured to run
```

### Transform Hooks

**Only transform when necessary for compatibility**:

```elixir
# GOOD - Transform for specific compatibility
def transform_outgoing(data, "mastodon.social", _actor_id) do
  # Mastodon-specific transformation
  data
  |> Map.put("@context", expanded_context())
  |> ensure_attachment_format(:mastodon)
end

def transform_outgoing(data, _host, _actor_id), do: data

# BAD - Unnecessary transformation
def transform_outgoing(data, _host, _actor_id) do
  # Modifying all outgoing data unnecessarily
  Map.put(data, "custom_field", "value")
end
```

## Best Practices Summary

### Validation Rules
- **Always validate** incoming data in your adapter
- **Never trust** remote content without sanitization
- **Always check** actor matches activity author

### Error Handling Rules
- **Always handle errors gracefully** - federation is unreliable
- **Never assume** remote instances are available
- **Always implement** timeouts and retries

### Privacy Rules
- **Never federate** private content
- **Always respect** user privacy settings
- **Always check** boundaries before federation

### Performance Rules
- **Always rate limit** incoming requests
- **Always monitor** queue depths
- **Always cache** but respect TTLs

### Compatibility Rules
- **Always test** with real implementations
- **Never assume** all instances behave identically
- **Always handle** both compact and expanded JSON-LD

### Deletion Rules
- **Always handle** Delete activities
- **Always create** Tombstone objects
- **Never hard-delete** federated content immediately

### Migration Rules
- **Always support** Move activities
- **Always update** follower lists
- **Never lose** follower relationships

## Resources

- [ActivityPub Specification](https://www.w3.org/TR/activitypub/)
- [ActivityStreams 2.0](https://www.w3.org/TR/activitystreams-core/)
- [HTTP Signatures](https://datatracker.ietf.org/doc/html/draft-cavage-http-signatures)
- [WebFinger](https://datatracker.ietf.org/doc/html/rfc7033)