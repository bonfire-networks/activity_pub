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
    def request(method, url, body \\ "", headers \\ [], options \\ []) do
      do_request(method, url, body, headers, options)
    end
  else
    def request(method, url, body \\ "", headers \\ [], options \\ []) do
      do_request(method, url, body, headers, options)
    rescue
      e in Tesla.Mock.Error ->
        error(e, "Test mock HTTP error")

      e ->
        error(e, "HTTP request failed")
    catch
      :exit, e ->
        error(e, "HTTP request exited")
    end
  end

  defp do_request(method, url, body, headers, options) do
    options =
      process_request_options(options)
      |> process_sni_options(url)

    # |> info("options")

    params = Keyword.get(options, :params, [])

    %{}
    |> Builder.method(method)
    |> Builder.headers(
      headers ++
        [
          {"User-Agent",
           Application.get_env(:activity_pub, :http)[:user_agent] || "ActivityPub Elixir library"}
        ]
    )
    |> Builder.opts(options)
    |> Builder.url(url)
    |> Builder.add_param(:body, :body, body)
    |> Builder.add_param(:query, :query, params)
    |> Enum.into([])
    |> (&Tesla.request(Connection.new(options), &1)).()
  end

  defp process_request_options(options) do
    Keyword.merge(Connection.hackney_options([]), options)
  end

  defp process_sni_options(options, nil), do: options

  defp process_sni_options(options, url) do
    uri = URI.parse(url)
    host = uri.host |> to_charlist()

    case uri.scheme do
      "https" -> options ++ [ssl: [server_name_indication: host]]
      _ -> options
    end
  end

  @doc """
  Makes a GET request

  see `ActivityPub.Federator.HTTP.request/5`
  """
  def get(url, headers \\ [], options \\ []),
    do: request(:get, url, "", headers, options)

  @doc """
  Makes a POST request

  see `ActivityPub.Federator.HTTP.request/5`
  """
  def post(url, body, headers \\ [], options \\ []),
    do: request(:post, url, body, headers, options)

  @doc """
  Makes a PUT request

  see `ActivityPub.Federator.HTTP.request/5`
  """
  def put(url, body, headers \\ [], options \\ []),
    do: request(:put, url, body, headers, options)

  @doc """
  Makes a DELETE request

  see `ActivityPub.Federator.HTTP.request/5`
  """
  def delete(url, body \\ "", headers \\ [], options \\ []),
    do: request(:delete, url, body, headers, options)
end
