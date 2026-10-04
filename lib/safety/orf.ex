defmodule ActivityPub.Safety.ORF do
  @moduledoc """
  Outgoing Request Filter: the counterpart of `ActivityPub.MRF` for the requests the instance makes, rather than the messages it receives.

  It's Tesla middleware run on every request the federation HTTP client makes (fetches, webfinger, nodeinfo, deliveries), and on every redirect hop, since it's plugged after `Tesla.Middleware.FollowRedirects`. So no caller has to remember to check:

  - hosts the instance doesn't federate with are refused, using `ActivityPub.Federator.Adapter.federation_allowed?/2` (block lists, allowlist-only mode). The direction is `:in` for GET/HEAD and `:out` otherwise, unless a `:direction` option is passed. Callers pass the user context in the request options (`:current_user`, `:by_actor`, `:user_ids`, see `federation_opts_keys/0`), so that user's own blocks apply too.
  - private, loopback and other reserved addresses are refused (Server-Side Request Forgery), using `ReqSSRF.check/2`. A `host:port` in the `:ssrf_allow_hosts` config (or set with `Process.put/2` in a test) skips this check for that hop only, e.g. for another instance in a local multi-instance setup. Extra `ReqSSRF` options can be set in the `:ssrf` config.

  Each host is checked on its own, including every redirect hop. So in allowlist-only mode, an instance whose handles use a different domain than the one it runs on (e.g. `@alice@example.com` served by `social.example.com`, with webfinger and nodeinfo on `example.com` pointing there) only federates if both domains are allowlisted.
  """
  @behaviour Tesla.Middleware

  alias ActivityPub.Federator.Adapter

  @impl Tesla.Middleware
  def call(env, next, _opts) do
    uri = URI.parse(env.url)

    cond do
      not Adapter.federation_allowed?(uri, federation_opts(env)) ->
        {:error, :not_allowed}

      (check = check_address(uri)) != :ok ->
        {:error, reason} = check
        {:error, {:ssrf, reason}}

      true ->
        Tesla.run(env, next)
    end
  end

  @federation_opts [:direction, :block_types, :by_actor, :user_ids, :current_user]

  # the context callers pass with the request (`HTTP.get(url, headers, opts)`), so a user's own blocks apply to requests made for them
  def federation_opts_keys, do: @federation_opts

  defp federation_opts(env) do
    env.opts
    |> Keyword.take(@federation_opts)
    |> Keyword.put_new_lazy(:direction, fn -> direction(env.method) end)
  end

  defp direction(method) when method in [:get, :head], do: :in
  defp direction(_), do: :out

  defp check_address(%URI{host: host, port: port} = uri) do
    if "#{host}:#{port}" in allow_hosts() do
      :ok
    else
      ReqSSRF.check(uri, Application.get_env(:activity_pub, :ssrf, []))
    end
  end

  defp allow_hosts,
    do:
      ProcessTree.get(:ssrf_allow_hosts) ||
        Application.get_env(:activity_pub, :ssrf_allow_hosts, [])
end
