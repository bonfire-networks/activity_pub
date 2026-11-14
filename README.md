# ActivityPub for Elixir

Welcome! This is a library for [Elixir](https://elixir-lang.org) that lets your app join the **fediverse**: the network of servers (Mastodon, Pleroma, Bonfire and many more) where people on one server can follow and talk to people on another. The servers speak a shared language called [ActivityPub](https://www.w3.org/TR/activitypub/), and this library speaks it for you.

It is the part of [Bonfire](https://bonfirenetworks.org) that does the talking, and [kazarma](https://kazar.ma/) uses it too. You are very welcome to use it in your own app, and to come and say hello any time, even if ActivityPub is new to you: in the [chat room](https://matrix.to/#/#activitypub-elixir-lib:matrix.org), or on the fediverse in the [Elixir & ActivityPub group](https://bonfire.cafe/group/Elixir_ActivityPub). Questions and half-baked ideas are welcome in both.

> **Not using Elixir?** That's fine, you are welcome here too. If you just want to run a fediverse server, have a look at [Bonfire](https://bonfirenetworks.org), the app built on this library.

## What it does for you

- **Talks to other servers.** It answers WebFinger, and serves actors, inboxes and outboxes.
- **Signs and checks.** It signs what you send and checks what arrives (HTTP signatures, Linked Data signatures, and [FEP-8b32](https://w3id.org/fep/8b32) proofs).
- **Fetches and remembers** remote people and posts.
- **Delivers** your activities to other servers, with retries, through [Oban](https://hexdocs.pm/oban) queues.
- **Looks after you.** It refuses private addresses, rate limits incoming requests, and runs moderation policies (MRF) on everything it stores.

## What stays yours

Your app keeps its own data (users, posts, follows) in whatever database you like. The library asks your app about them through a small **adapter** module that you write.

The library has tables of its own in PostgreSQL: an Oban job queue, and a JSON copy of the activities and objects it sends and receives.

To use it you need Elixir 1.20.2 or later (with OTP 29), Phoenix, Ecto with PostgreSQL, and Oban. It runs in production on Bonfire, and its API is still growing, in a backwards-compatible way. It is not on Hex yet, so install it from Git.

## Getting started

Here is the shape of it, step by step. By the end of step 6, other servers can find one of your people.

<!-- tabs-open -->

### 1. Dependencies

A Git dependency doesn't bring along everything the library needs, so list these yourself:

```elixir
{:activity_pub, github: "bonfire-networks/activity_pub"},
{:oban, "~> 2.17"},
{:finch, ">= 0.0.0"},
{:certifi, "~> 2.12"},
{:jason, "~> 1.0"},
# optional in the library, but its views need phoenix_live_view, which this brings
{:phoenix_live_dashboard, "~> 0.9"}
```

### 2. Adapter

This is where your app and the library meet: a module that tells the library how to find your actors. These seven callbacks are enough to put one of your people on the network:

```elixir
defmodule MyApp.Adapter do
  @behaviour ActivityPub.Federator.Adapter

  alias ActivityPub.Actor
  # yours: it finds and saves your users
  alias MyApp.Accounts

  # Where you live. WebFinger takes your host name from here.
  @impl true
  def base_url, do: MyAppWeb.Endpoint.url()

  @impl true
  def get_locale, do: "en"

  # Your actors, handed over as %ActivityPub.Actor{}.
  @impl true
  def get_actor_by_username(username), do: found(Accounts.one(username: username, local: true))

  @impl true
  def get_actor_by_ap_id(ap_id), do: found(Accounts.one(ap_id: ap_id))

  @impl true
  def get_actor_by_id(id), do: found(Accounts.one(id: id))

  # The instance's own actor: the library signs its fetches with it. Must return {:ok, actor}.
  @impl true
  def get_or_create_service_actor do
    Accounts.get_or_create_instance_actor()
    |> to_actor()
    |> ActivityPub.Safety.Keys.ensure_keys_present()
  end

  # The library saves things on your users, such as the keys it makes for them.
  @impl true
  def update_local_actor(%Actor{id: id}, params) do
    user = Accounts.one(id: id)

    # `keep_stored_keys`: save new keys only if there are none yet (requests can race to make them)
    if params[:keep_stored_keys] && user.keys do
      {:ok, to_actor(user)}
    else
      {:ok, user} = Accounts.update(user, Map.take(params, [:keys, :data]))
      {:ok, to_actor(user)}
    end
  end

  defp found(nil), do: {:error, :not_found}
  defp found(user), do: {:ok, to_actor(user)}

  # Your user, as the library wants to see it.
  defp to_actor(user) do
    %Actor{
      id: user.id,
      ap_id: user.ap_id,
      username: user.username,
      local: user.local,
      keys: user.keys,
      data: user.data,
      pointer_id: user.id,
      deactivated: false
    }
  end
end
```

`to_actor/1` is the one place where a user of yours becomes an `%ActivityPub.Actor{}`. Four of its fields are worth a word:

- `id` is your own id for the user, as a string. `"1001"` works; the number `1001` makes the library crash when it builds a cache key from it.
- `data` is the actor as it will be served, a map with string keys: `"id"` (the same URL as `ap_id`), `"type"` (say `"Person"`), `"preferredUsername"`, and `"inbox"`, `"outbox"`, `"followers"` and `"following"` as URLs. The library adds the public key and a few other fields but doesn't make those URLs up, so fill them in where the router in step 5 serves them: `ActivityPub.Actor.actor_url("alice")` gives the `"id"` (`https://your.host/pub/actors/alice`), and the other four are that plus `/inbox`, `/outbox`, `/followers` or `/following`. A `:map` (jsonb) column keeps it as it is.
- `keys` is the private key as a PEM string, and `nil` until there is one. The library makes it the first time it is needed and hands it to `update_local_actor/2` to be saved, so a text column will do.
- `pointer_id` is a second id for the user. The library keeps it in its `ap_object` table, in a column that only takes a [ULID](https://github.com/ulid/spec) (26 characters, such as `01M7BVN6J5ASZ9TKMCFGDMC12A`). If your ids already are ULIDs, use the same one for both; if not, keep a ULID beside yours: `Needle.UID.generate/0` makes one, and comes with the library. A UUID or an integer here is refused with an `Ecto.ChangeError`. (Bonfire calls these pointers; you don't need a table of them.)

The instance's own actor is an actor like the others, with an `ap_id` and `username` of its own (say `https://your.host/pub/actors/instance.actor` and `instance.actor`) and `data` of the same kind, which can't be empty: an `"id"`, a `"type"` such as `"Application"`, a `"preferredUsername"` and an `"inbox"` are enough to start.

The compiler will warn about the callbacks you haven't written yet, and that list is your to-do list: [Hearing back](#hearing-back) below goes through it.

### 3. Tables

Oban's first (skip that one if your app has them already), then the library's:

```bash
mix ecto.gen.migration add_oban
mix ecto.gen.migration add_activity_pub
```

Put these in the two new files:

```elixir
defmodule MyApp.Repo.Migrations.AddOban do
  use Ecto.Migration

  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down(version: 1)
end
```

```elixir
defmodule MyApp.Repo.Migrations.AddActivityPub do
  use Ecto.Migration

  # the library creates its indexes CONCURRENTLY, which Postgres refuses inside a transaction
  @disable_ddl_transaction true
  @disable_migration_lock true

  # added after `up/0`, each as a function of its own, in this order
  @later ~w(add_service_actor_uri add_object_boolean add_object_authenticated add_object_data_received
            add_object_in_reply_to_index add_object_coalesce_index add_object_actor_index
            add_object_username_index add_object_recipients_index add_object_prunable_index
            add_collection_member_table)a

  def up do
    ActivityPub.Migrations.up()
    Enum.each(@later, &apply(ActivityPub.Migrations, &1, []))
  end

  def down, do: :ok
end
```

```bash
mix ecto.migrate
```

> **Open:** no single call upgrades the tables yet. When a release adds an `add_*` function to [`ActivityPub.Migrations`](https://github.com/bonfire-networks/activity_pub/blob/main/lib/migrations.ex), call it from a new migration of yours, as the library's own tests do, one per function ([`priv/test_repo/migrations`](https://github.com/bonfire-networks/activity_pub/tree/main/priv/test_repo/migrations)).

### 4. Config

```elixir
# config/config.exs
# The library's defaults (the guard lets your first `mix deps.get` run before the file exists)
lib_config = Path.expand("../deps/activity_pub/config/activity_pub.exs", __DIR__)
if File.exists?(lib_config), do: import_config(lib_config)

config :activity_pub, :adapter, MyApp.Adapter
config :activity_pub, :repo, MyApp.Repo
config :tesla, adapter: {Tesla.Adapter.Finch, name: MyApp.Finch}

config :mime, :types, %{
  "application/json" => ["json"],
  "application/activity+json" => ["activity+json"],
  "application/ld+json" => ["ld+json"],
  "application/jrd+json" => ["jrd+json"]
}

config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    federator_incoming_mentions: 2,
    federator_incoming: 3,
    federator_incoming_follows: 2,
    federator_incoming_unverified: 1,
    federator_outgoing: 2,
    remote_fetcher: 1
  ]

# config/runtime.exs
# Without this, every fetch and delivery answers "Federation is disabled"
config :activity_pub, :instance, federating: true
```

After changing `:mime` types, run `mix deps.clean mime --build` once. Every setting has a comment in [`config/activity_pub.exs`](https://github.com/bonfire-networks/activity_pub/blob/main/config/activity_pub.exs).

### 5. Phoenix

Start `{Finch, name: MyApp.Finch}` and `{Oban, Application.fetch_env!(:my_app, Oban)}` in your supervision tree. Then:

```elixir
# in your endpoint, in place of your Plug.Parsers.
# Signatures cover a Digest of the raw body, so the endpoint has to keep it.
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Jason,
  body_reader: {ActivityPub.Web.Plugs.DigestPlug, :read_body, []}

# in your router. The library's routes pipe through two pipelines of yours, so define them first
# (you probably have :browser already, and :load_authorization can be empty).
pipeline :browser do
  plug :accepts, ["html"]
end

pipeline :load_authorization do
end

use ActivityPub.Web.Router
```

That adds WebFinger, actors with their inbox and outbox, the shared inbox, and the stored objects, under `/pub` (set `AP_BASE_PATH` at compile time to change it). [NodeInfo](https://github.com/bonfire-networks/nodeinfo) is a separate library that you add alongside.

### 6. See it work

Say you have a user called `alice`. Ask for her as another server would:

```bash
curl -H 'Accept: application/jrd+json' 'https://your.host/.well-known/webfinger?resource=acct:alice@your.host'
curl -H 'Accept: application/activity+json' 'https://your.host/pub/actors/alice'
```

You should get her actor back as JSON, with a `publicKey` in it. The first time she is asked for, the library makes her keys and has your `update_local_actor/2` save them. If there is no `publicKey`, the log says the keys could not be saved: check that `update_local_actor/2` returns the user with her new `keys`. And if you get `500` and `server error`, a callback is missing: the log says which.

To try two instances on `localhost`, list them in `config :activity_pub, :ssrf_allow_hosts, ["a.localhost:4001", "b.localhost:4002"]`, since private addresses are refused otherwise.

<!-- tabs-close -->

**Got it working?** Then one of your people is on the network, and what comes next has no single right answer: who may follow them (anyone, or only people you approve), where people from other servers live in your app, what a reply, a like or an unfollow should do. People choose differently, and the [chat room](https://matrix.to/#/#activitypub-elixir-lib:matrix.org) and the [group](https://bonfire.cafe/group/Elixir_ActivityPub) are where they talk about it, stuck or not.

## Hearing back

The other callbacks let people follow yours, and let your app hear from other servers. Add them as you go; the [adapter docs](https://github.com/bonfire-networks/activity_pub/blob/main/lib/federator/adapter.ex) describe each.

- `get_follower_local_ids/2` and `get_following_local_ids/2`: who follows whom, as the `pointer_id`s of step 2. The followers URL answers `500` until the first is there.
- `handle_activity/1`: an activity arrived from another server and passed the checks. Do what it means in your app. A Follow is the usual first one: see [below](#when-someone-follows-you).
- `maybe_create_remote_actor/1` and `update_remote_actor/1`: the library met a person on another server, or saw them change something. Keep your copy of them up to date. The first has to answer `{:ok, actor}`; an example is [below](#when-someone-follows-you).
- `get_redirect_url/1`: where a person's page is on your site, for browsers. It gets a username or the actor's JSON.
- `maybe_publish_object/2`: only if your app has objects of its own that the library should hand over by id. `{:ok, :not_published}` is a fine answer.

You can leave `activity_exists?/3` and `get_actors_by_ids/1` out, though the compiler will warn: the library answers `false` for the first, and for the second it asks `get_actor_by_id/1` once per id.

### When someone follows you

The library doesn't answer a Follow for you. It stores it, passes it to `handle_activity/1`, and leaves the yes or no to your app. A yes is an Accept:

```elixir
@impl true
def handle_activity(%ActivityPub.Object{local: false, data: %{"type" => "Follow"}} = follow) do
  with {:ok, followed} <- get_actor_by_ap_id(follow.data["object"]),
       {:ok, follower} <- get_actor_by_ap_id(follow.data["actor"]),
       # yours: wherever you keep who follows whom
       :ok <- MyApp.Follows.add(followed.id, follower.id),
       {:ok, _accept} <-
         ActivityPub.accept(%{to: [follower.ap_id], actor: followed, object: follow}) do
    :ok
  end
end

def handle_activity(_other), do: :ok
```

What arrives is an `%ActivityPub.Object{}` whose `data` is the activity, a map with string keys: `"type"` is `"Follow"`, and `"actor"` and `"object"` are URLs for who sent it and who it is for. `local: false` leaves out Follows from your own people, which pass through `handle_activity/1` too.

For the new follower to get what you write, two more callbacks have to agree on an id. The first is called when the library meets a person: save them, tell it which id is theirs, and answer `{:ok, actor}`. The second gives back the ids of an actor's followers.

```elixir
@impl true
def maybe_create_remote_actor(%Actor{} = actor) do
  user = Accounts.get_or_create_remote(actor.ap_id, actor.username, actor.data)
  {:ok, _} = ActivityPub.Object.update_existing([ap_id: actor.ap_id], %{pointer_id: user.id})
  {:ok, to_actor(user)}
end

@impl true
def get_follower_local_ids(%Actor{id: id}, _purpose), do: MyApp.Follows.followers(id)
```

Those ids are the `pointer_id`s of step 2. If they are your other ids, nothing fails: the followers list stays empty, and what you [send](#sending-something) reaches no one. With the right ones, it goes to each follower's inbox.

> **Open:** this walkthrough was run against a stand-in remote server on localhost, not against Mastodon, Pleroma or Lemmy, so a real server may still surprise you.

## Sending something

Everything you send goes through [`ActivityPub`](https://github.com/bonfire-networks/activity_pub/blob/main/lib/activity_pub.ex). Here is a public note, which the library addresses and queues for delivery to each follower's inbox:

```elixir
public = "https://www.w3.org/ns/activitystreams#Public"
followers = me.data["followers"]   # `me` is an %ActivityPub.Actor{}

{:ok, _} =
  ActivityPub.create(%{
    to: [public],
    actor: me,
    object: %{
      "type" => "Note",
      "content" => "Hello, fediverse",
      "attributedTo" => me.ap_id,
      "to" => [public],
      "cc" => [followers]
    },
    additional: %{"cc" => [followers]}
  })
```

The same module has `follow`, `accept`, `like`, `announce`, `update`, `delete`, `block` and more.

## Moderation

MRF (message rewrite facility) policies can rewrite or reject an object when it is stored. Turn them on with `config :activity_pub, :instance, rewrite_policy: [...]`. [`SimplePolicy`](https://github.com/bonfire-networks/activity_pub/blob/main/lib/safety/mrf/mrf_simple_policy.ex) and [`KeywordPolicy`](https://github.com/bonfire-networks/activity_pub/blob/main/lib/safety/mrf/mrf_keyword_policy.ex) come with it, and you can write your own with `@behaviour ActivityPub.MRF`.

## Learn more

- [Bonfire's federation interoperability guide](https://docs.bonfirenetworks.org/federation.html): what to know if you are building something that should work well with Bonfire (its endpoints, the FEPs it supports, and how it signs and checks requests).
- [bonfire_federate_activitypub](https://github.com/bonfire-networks/bonfire_federate_activitypub): Bonfire's adapter, a full example.
- [http_signatures](https://github.com/bonfire-networks/http_signatures): signs and checks HTTP signatures, used by this library.

## Contributing

Questions, ideas and fixes are welcome. This library is shared by several apps, so staying compatible (with them and with the fediverse) matters: for anything bigger than a small fix, please open an issue first (or ask in the [chat room](https://matrix.to/#/#activitypub-elixir-lib:matrix.org) or the [group](https://bonfire.cafe/group/Elixir_ActivityPub)), so we can talk it through together.

```text
lib/activity_pub.ex      the API your app calls
lib/federator/           adapter, delivery, fetching, WebFinger, Oban workers
lib/safety/              signatures, keys, SSRF guard, MRF policies
lib/web/                 router, controllers, plugs
priv/test_repo/          the migrations the tests run
```

`mix test` needs a PostgreSQL that [`config/test.exs`](https://github.com/bonfire-networks/activity_pub/blob/main/config/test.exs) can reach.

> **Open:** on a fresh clone `mix test` stops at four small things: `config/oban.exs` has no `import Config`; `mock` (through `meck`) doesn't build on OTP 29; the first test migration runs `Migrations.up()` inside a transaction, which refuses its `CONCURRENTLY` indexes; and `certifi` isn't declared. For now, `DB_MIGRATE_INDEXES_CONCURRENTLY=false` gets round the third, and `ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]'` the second.

## Credits and licence

Parts of the code come from [Akkoma](https://akkoma.social). Licensed under the GNU AGPLv3 (see [`LICENCE`](https://github.com/bonfire-networks/activity_pub/blob/main/LICENCE)).
