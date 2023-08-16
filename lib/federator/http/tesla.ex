defmodule ActivityPub.Federator.HTTP.Tesla do
  use Tesla
  plug Tesla.Middleware.FollowRedirects, max_redirects: 3
end
