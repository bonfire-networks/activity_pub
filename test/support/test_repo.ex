defmodule ActivityPub.TestRepo do
  use Ecto.Repo,
    otp_app: :activity_pub,
    adapter: Ecto.Adapters.Postgres
end
