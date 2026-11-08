defmodule ActivityPub.Federator.HTTP.SignFetch do
  @moduledoc """
  Signs a GET with the actor's key, for each request the stack sends, including each redirect hop.

  A signature covers the URL it was made for (`(request-target)` and `host` for draft-cavage, `@target-uri` for RFC 9421), so the signature of the first request does not hold for the URL a redirect points to. Plugged after `Tesla.Middleware.FollowRedirects`, this signs again at every hop, as `ActivityPub.Safety.ORF` checks again.

  It only signs a request that is given the `:sign_fetch` option, a keyword list of the options for `ActivityPub.Safety.Keys.maybe_add_fetch_signature_headers/3` (`:current_actor`, `:signature_format`, `:date`). Any other request goes through as it was.
  """
  @behaviour Tesla.Middleware

  alias ActivityPub.Safety.Keys

  @signature_headers ["signature", "signature-input", "date"]

  @impl Tesla.Middleware
  def call(env, next, _opts) do
    case env.opts[:sign_fetch] do
      sign_opts when is_list(sign_opts) -> env |> sign(sign_opts) |> Tesla.run(next)
      _ -> Tesla.run(env, next)
    end
  end

  defp sign(env, sign_opts) do
    # what the previous hop was signed with does not hold for this URL
    unsigned = Enum.reject(env.headers, fn {k, _} -> String.downcase(k) in @signature_headers end)

    case Keys.maybe_add_fetch_signature_headers(
           unsigned,
           Tesla.build_url(env.url, env.query),
           sign_opts
         ) do
      ^unsigned -> env
      signed -> %{env | headers: signed}
    end
  end
end
