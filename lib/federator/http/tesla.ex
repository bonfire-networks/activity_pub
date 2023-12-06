defmodule ActivityPub.Federator.HTTP.Tesla do
  use Tesla
  plug Tesla.Middleware.FollowRedirects, max_redirects: 3
  plug ActivityPub.Federator.HTTP.RateLimit
  plug TeslaExtra.RetryAfter
end
