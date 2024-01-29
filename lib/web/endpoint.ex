# NOTICE: We don't use this endpoint when running in library mode but some modules rely on functions provided by it...

defmodule ActivityPub.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :activity_pub

  socket("/socket", ActivityPub.Web.UserSocket,
    websocket: true,
    longpoll: false
  )

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug(Plug.Static,
    at: "/",
    from: :activity_pub,
    gzip: false,
    only: ~w(css fonts images js favicon.ico robots.txt)
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Logger)

  # parses real IP in conn if behind proxy 
  plug(RemoteIp)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {ActivityPub.Web.Plugs.DigestPlug, :read_body, []}
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  plug(Plug.Session,
    store: :cookie,
    key: "_activity_pub_key",
    signing_salt: "i4A5AOWF"
  )

  if Code.ensure_compiled(ActivityPub.Web.TestRouter) ==
       {:module, ActivityPub.Web.TestRouter} do
    plug(ActivityPub.Web.TestRouter)
  end
end
