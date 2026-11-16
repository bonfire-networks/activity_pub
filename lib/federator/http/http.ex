defmodule ActivityPub.Federator.HTTP do
  @moduledoc """
  Module for building and performing HTTP requests.
  """
  import Untangle
  alias ActivityPub.Federator.HTTP.Connection
  alias ActivityPub.Federator.HTTP.RequestBuilder, as: Builder

  @type t :: __MODULE__

  @doc """
  Builds and perform http request.

  # Arguments:
  `method` - :get, :post, :put, :delete
  `url`
  `body`
  `headers` - a keyworld list of headers, e.g. `[{"content-type", "text/plain"}]`
  `options` - custom, per-request middleware or adapter options

  # Returns:
  `{:ok, %Tesla.Env{}}` or `{:error, error}`

  """
  if ActivityPub.Config.env() == :test do
    def http_request(method, url, body \\ "", headers \\ [], options \\ []) do
      do_http_request(method, url, body, headers, options)
    end
  else
    def http_request(method, url, body \\ "", headers \\ [], options \\ []) do
      do_http_request(method, url, body, headers, options)
    rescue
      e in Tesla.Mock.Error ->
        error(e, "Test mock HTTP error")

        # e ->
        #   error(e, "HTTP request failed")
    catch
      :exit, e ->
        error(e, "HTTP request exited")
    end
  end

  defp do_http_request(method, url, body, headers, options) do
    debug(self(), "httpid")

    options =
      process_request_options(options)
      |> process_sni_options(url)

    # |> debug("options")

    {max_body_bytes, options} = Keyword.pop(options, :max_body_bytes)
    max_body_bytes = max_body_bytes || max_body_bytes()

    params = Keyword.get(options, :params, [])

    # the adapter stops reading the response at the limit
    options
    |> Keyword.update(
      :adapter,
      [max_body_bytes: max_body_bytes],
      &Keyword.put(&1, :max_body_bytes, max_body_bytes)
    )
    |> Connection.new()
    # |> debug("connection")
    |> ActivityPub.Federator.HTTP.Tesla.request(
      %{}
      |> Builder.method(method)
      |> Builder.headers(
        headers ++
          [
            {"User-Agent",
             "#{ActivityPub.Web.base_url()} - #{Application.get_env(:activity_pub, :http)[:user_agent] || "ActivityPub Elixir library"}"}
          ]
      )
      |> Builder.opts(options)
      |> Builder.url(url)
      |> Builder.add_param(:body, :body, body)
      |> Builder.add_param(:query, :query, params)
      |> Enum.into([])
      # |> IO.inspect(label: "HTTP built")
    )
    |> cap_body(max_body_bytes)

    # |> debug("requested")
  end

  @default_max_body_bytes 10 * 1024 * 1024

  @doc "The size over which a response body is refused (`config :activity_pub, :http, max_body_bytes: …`, 10 MB by default). Also the `:max_body_bytes` option of a request."
  def max_body_bytes,
    do: ActivityPub.Config.get([:http, :max_body_bytes], @default_max_body_bytes)

  # The adapter stops reading at the limit (`ActivityPub.Federator.HTTP.CappedFinch`); this covers the adapters that cannot, and answers that arrived whole.
  defp cap_body({:ok, %{body: body}} = result, max) when is_binary(body) do
    if byte_size(body) > max do
      error(max, "The response body is over the size limit")
      {:error, :body_too_large}
    else
      result
    end
  end

  defp cap_body(result, _max), do: result

  defp process_request_options(options) do
    {_adapter, opts} = Connection.adapter_options([])
    Keyword.merge(opts, options)
  end

  defp process_sni_options(options, nil), do: options

  defp process_sni_options(options, url) do
    uri = URI.parse(url)
    host = uri.host |> to_charlist()
    # |> debug("charlist")

    case uri.scheme do
      "https" ->
        Keyword.merge(options,
          ssl_options: [
            server_name_indication: host
          ]
        )

      _ ->
        options
    end
  end

  @doc """
  Makes a GET request

  see `ActivityPub.Federator.HTTP.http_request/5`
  """
  def get(url, headers \\ [], options \\ []),
    do: http_request(:get, url, "", headers, options)

  @doc """
  Makes a POST request

  see `ActivityPub.Federator.HTTP.http_request/5`
  """
  def post(url, body, headers \\ [], options \\ []),
    do: http_request(:post, url, body, headers, options)

  @doc """
  Makes a PUT request

  see `ActivityPub.Federator.HTTP.http_request/5`
  """
  def put(url, body, headers \\ [], options \\ []),
    do: http_request(:put, url, body, headers, options)

  @doc """
  Makes a DELETE request

  see `ActivityPub.Federator.HTTP.http_request/5`
  """
  def delete(url, body \\ "", headers \\ [], options \\ []),
    do: http_request(:delete, url, body, headers, options)
end
