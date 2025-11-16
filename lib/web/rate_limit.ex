defmodule ActivityPub.Web.RateLimit do
  @moduledoc """
  Rate limiter for ActivityPub using Hammer 7.x with ETS backend.

  Provides rate limiting for HTTP requests to protect against abuse.
  """

  use Hammer, backend: :ets
end
