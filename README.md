# ActivityPub

ActivityPub Library for elixir.

**HEAVY WORK IN PROGRESS, BREAKING API CHANGES EXPECTED**

## Installation

1. Add this library to your dependencies in `mix.exs`

```
defp deps do
  [...]
  {:activity_pub: git, "https://gitlab.com/CommonsPub/activitypub.git", branch: "stable"}
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

4. Inject AP routes to your router by adding `use ActivityPubWeb.Router` to your app's router module