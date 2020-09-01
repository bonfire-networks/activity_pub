defmodule ActivityPubWeb.Router do
  use ActivityPubWeb, :router

  ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

  pipeline :well_known do
    plug(:accepts, ["json", "jrd+json"])
  end

  pipeline :activity_pub do
    plug(:accepts, ["activity+json", "json", "html"])
  end

  pipeline :signed_activity_pub do
    plug(:accepts, ["activity+json", "json"])
    plug(ActivityPubWeb.Plugs.HTTPSignaturePlug)
  end

  scope "/.well-known", ActivityPubWeb do
    pipe_through(:well_known)

    get "/webfinger", WebFingerController, :webfinger
    get "/nodeinfo", NodeinfoController, :schemas
  end

  scope ap_base_path, ActivityPubWeb do
    pipe_through(:activity_pub)

    get "/objects/:uuid", ActivityPubController, :object
    get "/actors/:username", ActivityPubController, :actor
    get "/actors/:username/followers", ActivityPubController, :followers
    get "/actors/:username/following", ActivityPubController, :following
    get "/actors/:username/outbox", ActivityPubController, :noop
  end

  scope ap_base_path, ActivityPubWeb do
    pipe_through(:signed_activity_pub)

    post "/actors/:username/inbox", ActivityPubController, :inbox
    post "/shared_inbox", ActivityPubController, :inbox
  end
end
