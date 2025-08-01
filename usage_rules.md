# ActivityPub Library Usage Rules and Documentation

## Overview

This is the core ActivityPub federation library for Bonfire and other Elixir applications. It provides a comprehensive implementation of the ActivityPub protocol with an adapter-based architecture that allows host applications to integrate federation capabilities while maintaining control over their domain logic.

**IMPORTANT**: This is a low-level library that handles ActivityPub protocol details. It requires implementing an adapter module to connect with your application's data models and business logic.

## Architecture

### Core Design Principles

1. **Adapter Pattern**: The library delegates application-specific operations to an adapter module that you must implement
2. **Object Storage**: All ActivityPub objects and activities are stored in a dedicated `ap_object` table
3. **Actor Management**: Supports both local and remote actors with key management
4. **Caching**: Extensive caching for performance (actors, objects, JSON responses)
5. **Safety First**: Built-in MRF policies, HTTP signatures, and instance management

### Module Structure

```
ActivityPub
├── Core Modules
│   ├── ActivityPub          # Main entry point for activities
│   ├── Actor               # Actor management (Person, Group, etc.)
│   └── Object              # Object/Activity storage and queries
├── Federator
│   ├── Federator           # Publishing orchestration
│   ├── Fetcher            # Remote object fetching
│   ├── Publisher          # Outgoing federation
│   ├── Transformer        # Data normalization
│   └── APPublisher        # ActivityPub publishing implementation
├── Safety
│   ├── MRF                # Message Rewrite Facility
│   ├── Keys               # RSA key management
│   ├── Containment        # Origin verification
│   └── HTTP.Signatures    # HTTP signature verification
├── Web
│   ├── Controllers        # HTTP endpoints
│   ├── Views             # JSON rendering
│   └── Router            # Route definitions
└── Workers               # Background job processing
```

## Adapter Implementation

Your adapter module must implement the `ActivityPub.Federator.Adapter` behaviour:

### Required Callbacks

```elixir
defmodule MyApp.ActivityPubAdapter do
  @behaviour ActivityPub.Federator.Adapter

  # Base URL for your instance
  @impl true
  def base_url, do: "https://myapp.example.com"

  # Actor retrieval functions
  @impl true
  def get_actor_by_id(id) do
    # Return {:ok, %ActivityPub.Actor{}} or {:error, :not_found}
  end

  @impl true
  def get_actor_by_username(username) do
    # Return {:ok, %ActivityPub.Actor{}} or {:error, :not_found}
  end

  @impl true
  def get_actor_by_ap_id(ap_id) do
    # Return {:ok, %ActivityPub.Actor{}} or {:error, :not_found}
  end

  # Actor management
  @impl true
  def maybe_create_remote_actor(%ActivityPub.Actor{} = actor) do
    # Create or update remote actor in your database
    # Return {:ok, your_actor_struct}
  end

  @impl true
  def update_local_actor(actor, params) do
    # Update local actor with new fields (e.g., keys)
    # Return {:ok, %ActivityPub.Actor{}}
  end

  @impl true
  def update_remote_actor(object_or_actor) do
    # Update remote actor from fresh data
    # Return :ok
  end

  # Activity handling
  @impl true
  def handle_activity(%ActivityPub.Object{} = activity) do
    # Process incoming activity (Create, Follow, Like, etc.)
    # Return {:ok, result} or {:error, reason}
  end

  # Social graph
  @impl true
  def get_follower_local_ids(actor, _purpose) do
    # Return list of local follower IDs
  end

  @impl true
  def get_following_local_ids(actor, _purpose) do
    # Return list of local following IDs
  end

  # Publishing
  @impl true
  def maybe_publish_object(id, manually_fetching?) do
    # Convert your object to ActivityPub format
    # Return {:ok, %ActivityPub.Object{}}
  end

  # UI/Routing
  @impl true
  def get_redirect_url(id_or_username) do
    # Return URL to redirect to in browser
  end

  # Service actor
  @impl true
  def get_or_create_service_actor do
    # Return instance actor for signing fetches
  end

  # Federation control
  @impl true
  def federate_actor?(actor, direction, by_actor) do
    # Return true/false/nil to control federation
  end
end
```

### Actor Structure

Actors must be returned as `%ActivityPub.Actor{}` structs:

```elixir
%ActivityPub.Actor{
  id: "internal_db_id",
  data: %{
    "id" => "https://example.com/users/alice",
    "type" => "Person",
    "preferredUsername" => "alice",
    "inbox" => "https://example.com/users/alice/inbox",
    "outbox" => "https://example.com/users/alice/outbox",
    "followers" => "https://example.com/users/alice/followers",
    "following" => "https://example.com/users/alice/following",
    # ... other ActivityStreams properties
  },
  local: true,
  keys: "-----BEGIN RSA PRIVATE KEY-----...",  # Only for local actors
  ap_id: "https://example.com/users/alice",
  username: "alice@example.com",
  pointer_id: "your_app_actor_id",
  deactivated: false
}
```

## Core Operations

### Creating Activities

```elixir
# Create a Note
ActivityPub.create(%{
  to: ["https://www.w3.org/ns/activitystreams#Public"],
  actor: actor,
  context: context_id,
  object: %{
    "type" => "Note",
    "content" => "Hello, Fediverse!",
    "to" => ["https://www.w3.org/ns/activitystreams#Public"]
  },
  local: true
})

# Follow someone
ActivityPub.follow(%{
  actor: follower,
  object: followed,
  local: true
})

# Like an object
ActivityPub.like(%{
  actor: liker,
  object: object_to_like,
  local: true
})

# Announce (boost/share)
ActivityPub.announce(%{
  actor: announcer,
  object: object_to_announce,
  local: true,
  public: true
})
```

### Actor Operations

```elixir
# Get actor (cached)
{:ok, actor} = ActivityPub.Actor.get_cached(username: "alice@example.com")
{:ok, actor} = ActivityPub.Actor.get_cached(ap_id: "https://example.com/users/alice")

# Get or fetch remote actor
{:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)

# Update actor (triggers refetch)
{:ok, actor} = ActivityPub.Actor.update_actor(ap_id, nil)
```

### Object Operations

```elixir
# Get object (cached)
{:ok, object} = ActivityPub.Object.get_cached(ap_id: object_id)

# Normalize (get cached or fetch)
object = ActivityPub.Object.normalize(object_id_or_map)

# Get activity for object
activity = ActivityPub.Object.get_activity_for_object_ap_id(object_id)
```

## Federation Flow

### Incoming Activities

1. **HTTP Request** → `IncomingActivityPubController` 
2. **Signature Verification** → `FetchHTTPSignaturePlug`
3. **MRF Filtering** → `ActivityPub.MRF`
4. **Processing** → `ReceiverWorker` → `Federator.Transformer.handle_incoming/2`
5. **Storage** → `ActivityPub.Object.insert/3`
6. **Adapter Callback** → `Adapter.handle_activity/1`

### Outgoing Activities

1. **Activity Creation** → `ActivityPub.create/1` (or other activity functions)
2. **Storage** → `ActivityPub.Object.insert/3`
3. **Publishing** → `ActivityPub.Federator.publish/2`
4. **Queue** → `PublisherWorker`
5. **Delivery** → `APPublisher.publish/2`
6. **HTTP Delivery** → Per-inbox delivery with signatures

### Object Fetching

1. **Request** → `Fetcher.fetch_object_from_id/2`
2. **HTTP Fetch** → With signature headers
3. **Validation** → Origin containment
4. **Transform** → `Transformer.handle_incoming/2`
5. **Storage** → If valid
6. **Adapter** → `maybe_create_remote_actor/1` or `handle_activity/1`

## Security & Safety

### HTTP Signatures

- All local actors have RSA keypairs (auto-generated)
- Outgoing requests are signed (POST always, GET configurable)
- Incoming POST requests require valid signatures
- Key fetching with caching

### MRF (Message Rewrite Facility)

Configure policies in your app's config:

```elixir
config :activity_pub, :instance,
  rewrite_policy: [ActivityPub.MRF.SimplePolicy]

config :activity_pub, :mrf_simple,
  reject: ["bad.example.com"],
  media_removal: ["nsfw.example.com"],
  report_removal: ["spam.example.com"]
```

### Instance Management

- Automatic reachability tracking
- Exponential backoff for unreachable instances
- Instance-level filtering via MRF

## Configuration

### Required Configuration

```elixir
# Adapter module
config :activity_pub, :adapter, MyApp.ActivityPubAdapter

# Database repo
config :activity_pub, :repo, MyApp.Repo

# Instance settings
config :activity_pub, :instance,
  hostname: "myapp.example.com",
  federating: true
```

### Optional Configuration

```elixir
# HTTP settings
config :activity_pub, :http,
  proxy_url: nil,
  user_agent: "MyApp/1.0",
  send_user_agent: true

# Federation settings
config :activity_pub, :instance,
  federation_reachability_timeout_days: 7,
  federation_publisher_modules: [ActivityPub.Federator.APPublisher],
  rewrite_policy: []

# Object signing for GET requests
config :activity_pub, :sign_object_fetches, true

# Federation limits
config :activity_pub, :instance,
  federation_incoming_max_recursion: 10,
  federation_incoming_max_items: 5
```

## Common Patterns

### Handling Incoming Activities

In your adapter's `handle_activity/1`:

```elixir
def handle_activity(%{data: %{"type" => "Create", "object" => object}} = activity) do
  with {:ok, local_object} <- create_from_ap(object),
       {:ok, _} <- notify_users(local_object) do
    {:ok, local_object}
  end
end

def handle_activity(%{data: %{"type" => "Follow"}} = activity) do
  with {:ok, follow} <- create_follow_request(activity),
       {:ok, _} <- maybe_auto_accept(follow) do
    {:ok, follow}
  end
end
```

### Publishing Local Content

```elixir
# In your app's create post function
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
  end
end
```

### Implementing Federation Controls

```elixir
def federate_actor?(actor, :in, _by_actor) do
  # Check if we accept incoming activities from this actor
  not actor_blocked?(actor)
end

def federate_actor?(actor, :out, _by_actor) do
  # Check if we federate this actor's content
  actor.local and not actor.private
end
```

## Testing

### Mock Adapter

Create a mock adapter for tests:

```elixir
defmodule MyApp.MockAdapter do
  @behaviour ActivityPub.Federator.Adapter
  
  # Implement all callbacks with simple in-memory storage
  # See Bonfire's implementation for examples
end
```

### HTTP Mocking

Use Tesla.Mock for HTTP requests:

```elixir
Tesla.Mock.mock(fn
  %{url: "https://remote.example/actor"} ->
    %Tesla.Env{status: 200, body: actor_json}
end)
```

## Performance Considerations

1. **Caching**: Heavy caching of actors and objects (Cachex)
2. **Background Jobs**: All federation happens in background (Oban)
3. **Batch Delivery**: Activities are delivered to multiple inboxes concurrently
4. **Connection Pooling**: Reuse HTTP connections per host

## Debugging

Enable debug logging:

```elixir
config :activity_pub, :debug, true
```

Check federation queues:

```elixir
# In IEx
Oban.Job |> Repo.all() |> Enum.group_by(& &1.queue)
```

## Common Pitfalls

1. **Missing Routes**: Remember to add `use ActivityPub.Web.Router` to your router
2. **Unsigned Fetches**: Some instances require signed GET requests
3. **Key Generation**: Local actors need keys before publishing
4. **Pointer IDs**: Must be unique per object type (actors, objects)
5. **Public Addressing**: Use full URI "https://www.w3.org/ns/activitystreams#Public"

## Extension Points

### Custom Activity Types

Add to config:

```elixir
config :activity_pub, :instance,
  supported_activity_types: ["Create", "Update", "Delete", "CustomType"]
```

### Custom MRF Policies

```elixir
defmodule MyApp.CustomMRFPolicy do
  @behaviour ActivityPub.MRF
  
  @impl true
  def filter(object, local?) do
    # Modify or reject based on your rules
    {:ok, object}
  end
end
```

### Transform Hooks

In your adapter:

```elixir
def transform_outgoing(data, target_host, target_actor_id) do
  # Modify outgoing data per-recipient
  data
end
```

## Best Practices

1. **Always validate** incoming data in your adapter
2. **Handle errors gracefully** - federation is unreliable
3. **Respect privacy** - don't federate private content
4. **Rate limit** incoming requests
5. **Monitor queues** to detect federation issues
6. **Test with real instances** using ngrok or similar
7. **Implement proper logging** for debugging
8. **Cache aggressively** but respect cache invalidation
9. **Handle deletions** properly (Tombstones)
10. **Support account migrations** (Move activities)

## Resources

- [ActivityPub Specification](https://www.w3.org/TR/activitypub/)
- [ActivityStreams 2.0](https://www.w3.org/TR/activitystreams-core/)
- [HTTP Signatures](https://datatracker.ietf.org/doc/html/draft-cavage-http-signatures)
- [WebFinger](https://datatracker.ietf.org/doc/html/rfc7033)