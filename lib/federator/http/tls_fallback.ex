defmodule ActivityPub.Federator.HTTP.TLSFallback do
  @moduledoc """
  Repeats a request whose TLS 1.3 handshake `:ssl` refused with `unexpected_message`, through `Tesla.Adapter.Mint` with TLS 1.3 middlebox compatibility mode off. It remembers the host (`ActivityPub.Instances.get_host_cache/2`, key `:tls_compat`), so later requests to it go through Mint directly.

  Some servers (eg. h2o) answer OTP's first key share with a HelloRetryRequest and then skip the compatibility ChangeCipherSpec that `:ssl` waits for. Every other host keeps the default handshake. Mint opens one connection per request, with the proxy and transport options of the configured Finch adapter's default pool, and verifies the peer as usual.

  Plug it last, next to the adapter, so that redirects, retries and the other middleware wrap the repeated request too.
  """
  @behaviour Tesla.Middleware

  import Untangle
  alias ActivityPub.Instances

  # Finch's own default, as Mint's adapter would otherwise wait only 2 seconds for a response
  @default_receive_timeout to_timeout(second: 15)

  @impl Tesla.Middleware
  def call(env, next, _opts) do
    host = Instances.host(env.url)

    if Instances.get_host_cache(host, :tls_compat) do
      via_mint(env)
    else
      case Tesla.run(env, next) do
        {:error, {:tls_alert, {:unexpected_message, _}}} = refused ->
          warn(
            refused,
            "TLS handshake refused by #{host}, repeating the request with TLS 1.3 middlebox compatibility mode off"
          )

          with {:ok, _} = result <- via_mint(env) do
            Instances.put_host_cache(host, :tls_compat, true)
            result
          end

        other ->
          other
      end
    end
  end

  defp via_mint(env), do: Tesla.Adapter.Mint.call(env, mint_opts())

  defp mint_opts do
    finch_opts =
      case Application.get_env(:tesla, :adapter) do
        {Tesla.Adapter.Finch, opts} -> opts
        _ -> []
      end

    conn_opts = get_in(finch_opts, [:pools, :default, :conn_opts]) || []

    [
      timeout: finch_opts[:receive_timeout] || @default_receive_timeout,
      transport_opts: Keyword.put(conn_opts[:transport_opts] || [], :middlebox_comp_mode, false)
    ] ++ Keyword.take(conn_opts, [:proxy])
  end
end
