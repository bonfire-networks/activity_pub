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

      pipeline :activity_json do
        plug(:accepts, ["json", "activity+json", "ld+json"])
      end

      pipeline :activity_json_or_html do
        plug(:accepts, ["json", "activity+json", "ld+json", "html"])
      end

      pipeline :signed_activity_pub_incoming do
        plug(ActivityPub.Web.Plugs.HTTPSignaturePlug)
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
        get("/shared_outbox", ActivityPubController, :outbox)
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

        # URLs for interop with Mastodon clients / AP testing tools
        post("/users/:username", IncomingActivityPubController, :inbox)
        post("/users/:username/inbox", IncomingActivityPubController, :inbox)

        # return error saying not supported
        post("/users/:username/outbox", IncomingActivityPubController, :outbox_info)
      end

      scope unquote(ap_base_path), ActivityPub.Web do
        pipe_through(:activity_json)
        pipe_through(:load_authorization)
        pipe_through(:signed_activity_pub_incoming)

        post("/actors/:username/inbox", IncomingActivityPubController, :inbox)
        # TODO: implement this for AP C2S API
        post("/actors/:username/outbox", IncomingActivityPubController, :outbox_info)
        post("/shared_inbox", IncomingActivityPubController, :inbox)
      end

      scope unquote(ap_base_path), ActivityPub.Web do
        pipe_through(:browser)

        get("/remote_interaction", RedirectController, :remote_interaction)
        post("/remote_interaction", RedirectController, :remote_interaction)
      end
    end
  end
end
