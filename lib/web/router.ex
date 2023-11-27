defmodule ActivityPub.Web.Router do
  defmacro __using__(_) do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    quote do
      pipeline :well_known do
        plug(:accepts, ["json", "jrd+json", "activity+json", "ld+json"])
      end

      pipeline :activity_pub do
        plug(:accepts, ["activity+json", "ld+json", "json", "html"])
      end

      # should be already defined in the actual router which is calling this macro
      # pipeline :browser do
      #   plug(:accepts, ["html"])
      # end

      pipeline :signed_activity_pub do
        plug(:accepts, ["activity+json", "ld+json", "json"])
        plug(ActivityPub.Web.Plugs.HTTPSignaturePlug)
        # plug(ActivityPub.Web.Plugs.MappedSignatureToIdentityPlug)
        # plug(ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug)
      end

      scope "/.well-known", ActivityPub.Web do
        pipe_through(:well_known)

        get("/webfinger", WebFingerController, :webfinger)
      end

      scope unquote(ap_base_path), ActivityPub.Web do
        # pipe_through(:signed_activity_pub) # TODO: check signature of fetches too
        pipe_through(:activity_pub)

        get("/objects/:uuid", ActivityPubController, :object)

        # note: singular is not canonical
        get("/object/:uuid", ActivityPubController, :object)

        get("/actors/:username", ActivityPubController, :actor)
        get("/actors/:username/followers", ActivityPubController, :followers)
        get("/actors/:username/following", ActivityPubController, :following)
        get("/actors/:username/outbox", ActivityPubController, :outbox)

        # note: singular is not canonical
        get("/actor/:username", ActivityPubController, :actor)

        get("/shared_inbox", ActivityPubController, :inbox_info)
      end

      scope unquote(ap_base_path), ActivityPub.Web do
        pipe_through(:signed_activity_pub)

        post("/actors/:username/inbox", ActivityPubController, :inbox)
        post("/shared_inbox", ActivityPubController, :inbox)
      end

      scope unquote(ap_base_path), ActivityPub.Web do
        pipe_through(:browser)

        get("/remote_interaction", RedirectController, :remote_interaction)
        post("/remote_interaction", RedirectController, :remote_interaction)
      end
    end
  end
end
