defmodule ActivityPub.Web.Router do
  defmacro __using__(_) do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    quote do
      # should be already defined in the actual router which is calling this macro
      # pipeline :browser do
      #   plug(:accepts, ["html"])
      # end

      pipeline :html_only do
        plug(:accepts, ["html"])
      end

      pipeline :webfinger do
        plug(:accepts, ["json", "jrd+json", "activity+json", "ld+json"])
      end

      # host-meta accepts any content type since it always returns XML
      pipeline :host_meta do
        plug(:accepts, ~w(xml xrd+xml html json activity+json ld+json jrd+json))
      end

      pipeline :activity_json do
        plug(:accepts, ["json", "activity+json", "ld+json"])
      end

      pipeline :activity_json_or_html do
        plug(:accepts, ["json", "activity+json", "ld+json", "html"])
      end

      pipeline :signed_activity_pub_incoming do
        plug(ActivityPub.Web.Plugs.FetchHTTPSignaturePlug)
        plug(ActivityPub.Web.Plugs.MappedSignatureToIdentityPlug)
        plug(ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug)
      end

      pipeline :signed_activity_pub_fetch do
        plug(ActivityPub.Web.Plugs.FetchHTTPSignaturePlug)
        plug(ActivityPub.Web.Plugs.MappedSignatureToIdentityPlug)
        plug(ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug)
      end

      scope "/.well-known", ActivityPub.Web do
        pipe_through(:webfinger)

        get("/webfinger", WebFingerController, :webfinger)
      end

      scope "/.well-known", ActivityPub.Web do
        pipe_through(:host_meta)

        get("/host-meta", WebFingerController, :host_meta)
      end

      scope unquote(ap_base_path), ActivityPub.Web do
        pipe_through(:activity_json)
        pipe_through(:load_authorization)
        pipe_through(:signed_activity_pub_fetch)

        get("/actors/:username/followers", ActivityPubController, :followers)
        get("/actors/:username/following", ActivityPubController, :following)
        get("/actors/:username/outbox", ActivityPubController, :outbox)
        # maybe return inbox, or error saying only POST supported
        get("/actors/:username/inbox", ActivityPubController, :maybe_inbox)
      end

      scope unquote(ap_base_path), ActivityPub.Web do
        pipe_through(:activity_json_or_html)
        pipe_through(:load_authorization)
        pipe_through(:signed_activity_pub_fetch)

        get("/objects/:uuid", ActivityPubController, :object)
        # note: singular is not canonical
        get("/object/:uuid", ActivityPubController, :object)

        get("/actors/:username", ActivityPubController, :actor)
        # options("/actors/:username", ActivityPubController, :actor) 
        # note: singular is not canonical
        get("/actor/:username", ActivityPubController, :actor)

        # maybe return the public outbox
        get("/shared_outbox", ActivityPubController, :shared_outbox)
        # maybe return inbox, or error saying only POST supported
        get("/shared_inbox", ActivityPubController, :maybe_inbox)
      end

      scope "/", ActivityPub.Web do
        pipe_through(:activity_json_or_html)
        pipe_through(:load_authorization)
        pipe_through(:signed_activity_pub_fetch)

        # URLs for interop with Mastodon clients / AP testing tools
        # get("/api/v1/timelines/public", ActivityPubController, :outbox) # maybe return the public outbox 
        get("/users/:username", ActivityPubController, :actor)
      end

      scope "/", ActivityPub.Web do
        pipe_through(:activity_json)

        pipe_through(:load_authorization)
        pipe_through(:signed_activity_pub_incoming)

        # URLs for interop with  some AP testing tools 
        post("/users/:username", IncomingActivityPubController, :inbox)
        post("/users/:username/inbox", IncomingActivityPubController, :inbox)

        # post("/users/:username/outbox", IncomingActivityPubController, :only_get_error!)  # return error saying not supported
        post("/users/:username/outbox", C2SOutboxController, :create)
      end

      scope unquote(ap_base_path), ActivityPub.Web do
        pipe_through(:activity_json)
        pipe_through(:load_authorization)
        pipe_through(:signed_activity_pub_incoming)

        # inbox
        post("/actors/:username/inbox", IncomingActivityPubController, :inbox)
        post("/shared_inbox", IncomingActivityPubController, :shared_inbox)

        # outbox
        # post("/actors/:username/outbox", IncomingActivityPubController, :only_get_error!) # return error saying not supported
        post("/actors/:username/outbox", C2SOutboxController, :create)

        # proxy for c2s to get remote objects
        post("/proxy_remote_object", ProxyRemoteObjectController, :proxy)
        get("/proxy_remote_object", ProxyRemoteObjectController, :proxy)
      end

      scope unquote(ap_base_path), ActivityPub.Web do
        pipe_through(:browser)

        get("/remote_interaction", RedirectController, :remote_interaction)
        post("/remote_interaction", RedirectController, :remote_interaction)
      end

      scope "/", ActivityPub.Web do
        pipe_through(:browser)

        # alias /authorize_interaction to /pub/remote_interaction because mastodon seems to hardcode that URL 
        get("/authorize_interaction", RedirectController, :remote_interaction)
        post("/authorize_interaction", RedirectController, :remote_interaction)
      end
    end
  end
end
