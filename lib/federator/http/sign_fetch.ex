defmodule ActivityPub.Federator.HTTP.SignFetch do
  @moduledoc """
  Signs a GET with the actor's key, for each request the stack sends, including each redirect hop.

  A signature covers the URL it was made for (`(request-target)` and `host` for draft-cavage, `@target-uri` for RFC 9421), so the signature of the first request does not hold for the URL a redirect points to. Plugged after `Tesla.Middleware.FollowRedirects`, this signs again at every hop, as `ActivityPub.Safety.ORF` checks again.

  It only signs a request that is given the `:sign_fetch` option, a keyword list of the options for `ActivityPub.Safety.Keys.maybe_add_fetch_signature_headers/3` (`:current_actor`, `:signature_format`, `:date`). Any other request goes through as it was.
  """
  @behaviour Tesla.Middleware

  alias ActivityPub.Safety.Keys
  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter

  @signature_headers ["signature", "signature-input", "date"]

  @impl Tesla.Middleware
  def call(env, next, _opts) do
    case env.opts[:sign_fetch] do
      sign_opts when is_list(sign_opts) ->
        sign_opts = sign_opts_for_host(sign_opts, env.url)

        # kept in the request's options, which `FollowRedirects` carries to the next hop, so that hop knows which host and format this one used
        %{env | opts: Keyword.put(env.opts, :sign_fetch, sign_opts)}
        |> sign(sign_opts)
        |> Tesla.run(next)

      _ ->
        Tesla.run(env, next)
    end
  end

  # The signature format is the one the first URL's host was found to take. After a redirect to another host, the format cached for that host is used instead (a cache read only, never a request), else the one the request already uses. Within the same host nothing is looked up.
  defp sign_opts_for_host(sign_opts, url) do
    host = ActivityPub.Utils.authority(url)

    case sign_opts[:host] do
      ^host ->
        sign_opts

      nil ->
        Keyword.put(sign_opts, :host, host)

      _previous_host ->
        sign_opts
        |> Keyword.put(:host, host)
        |> Keyword.put(
          :signature_format,
          SignaturesAdapter.get_signature_format(host) || sign_opts[:signature_format]
        )
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
