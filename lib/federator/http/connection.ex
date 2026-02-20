defmodule ActivityPub.Federator.HTTP.Connection do
  import Untangle

  @moduledoc """
  Specifies connection options for HTTP requests
  """

  def new(opts \\ []) do
    adapter = Application.get_env(:tesla, :adapter, {Tesla.Adapter.Finch, name: Bonfire.Finch})

    Tesla.client(
      [],
      adapter_options(adapter, Keyword.get(opts, :adapter, [])) |> debug("adapter_options")
    )
  end

  def adapter_options(adapter \\ Tesla.Adapter.Hackney, opts)

  def adapter_options(Tesla.Adapter.Hackney, opts) do
    adapter_options = Application.get_env(:activity_pub, :http)[:adapter] || []
    proxy_url = Application.get_env(:activity_pub, :http)[:proxy_url]

    {Tesla.Adapter.Hackney,
     [
       connect_timeout: 10_000,
       recv_timeout: 20_000,
       follow_redirect: true,
       pool: :federation,
       ssl_options: [
         # insecure: false,
         # versions: [:'tlsv1.2'],
         verify: :verify_peer,
         cacertfile: :certifi.cacertfile(),
         verify_fun: &:ssl_verify_hostname.verify_fun/3
         # customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)] 
       ]
     ]
     |> Keyword.merge(adapter_options)
     |> Keyword.merge(opts)
     |> Keyword.merge(proxy: proxy_url)}
  end

  def adapter_options({adapter, base_opts}, opts), do: {adapter, Keyword.merge(base_opts, opts)}
  def adapter_options(adapter, opts), do: {adapter, opts}
end
