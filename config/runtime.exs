import Config

# Env vars read when the app starts, over the defaults in `activity_pub.exs`. Each sets its key only when it is set. An app that uses this library reads them in its own runtime config (Bonfire: `Bonfire.Federate.ActivityPub.RuntimeConfig`).

# a delivery with no signature of any kind, which its origin does not serve either, is accepted with ACCEPT_UNSIGNED_ACTIVITIES=1
if System.get_env("ACCEPT_UNSIGNED_ACTIVITIES") == "1" do
  config :activity_pub, :incoming_signatures, unsigned: :accept
end
