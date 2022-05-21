# ActivityPub

ActivityPub Library for elixir.

**WORK IN PROGRESS, TESTING FEDERATION WITH DIFFERENT IMPLEMENTATIONS IS UNDERWAY**

## Installation

1. Add this library to your dependencies in `mix.exs`

```
defp deps do
  [...]
  {:activity_pub: git, "https://github.com/bonfire-networks/activity_pub.git", branch: "stable"} # branch can "stable", or "develop" for the bleeding edge
end
```

2. Create an adapter module (more on that later) and set it in config

```
config :activity_pub, :adapter, MyApp.MyAdapter
```

3. Set your application repo in config

```
config :activity_pub, :repo, MyApp.Repo
```

4. Create a new ecto migration and call `ActivityPub.Migration.up/0` from it

5. Inject AP routes to your router by adding `use ActivityPubWeb.Router` to your app's router module

6. Copy the default AP config to your app's confix.exs

```
config :activity_pub, :mrf_simple,
  media_removal: [],
  media_nsfw: [],
  report_removal: [],
  accept: [],
  avatar_removal: [],
  banner_removal: []

config :activity_pub, :instance,
  hostname: "example.com",
  federation_publisher_modules: [ActivityPubWeb.Publisher],
  federation_reachability_timeout_days: 7,
  federating: true,
  rewrite_policy: []

config :activity_pub, :http,
  proxy_url: nil,
  send_user_agent: true,
  adapter: [
    ssl_options: [
      # Workaround for remote server certificate chain issues
      partial_chain: &:hackney_connect.partial_chain/1,
      # We don't support TLS v1.3 yet
      versions: [:tlsv1, :"tlsv1.1", :"tlsv1.2"]
    ]
  ]
  ```

7. Change the hostname value in the instance config block to your instance's hostname 

8. If you don't already have Oban set up, follow the [Oban installation intructions](https://hexdocs.pm/oban/installation.html#content) and add the AP queues:

```
config :my_app, Oban, queues: [federator_incoming: 50, federator_outgoing: 50]
```

Now you should be able to compile and run your app and move over to integration.
