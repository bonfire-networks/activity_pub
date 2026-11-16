defmodule ActivityPub.Federator.HTTP.CappedFinch do
  @moduledoc """
  A Tesla adapter over Finch that stops reading a response at a size limit, instead of reading all of it and comparing afterwards.

  A remote server may answer with whatever it likes, so with the `:max_body_bytes` adapter option set:

  - a `content-length` over the limit is refused as soon as the headers are in, before any of the body is read
  - a body with no (or a wrong) `content-length` is read only until it goes over the limit, and the connection is then closed

  Either way the result is `{:error, :body_too_large}`. Without the option this is `Tesla.Adapter.Finch`, and so are requests with a body that is not a binary (multipart, streams), as those are uploads.
  """
  @behaviour Tesla.Adapter

  import Tesla.Adapter.Shared, only: [format_method: 1]

  @defaults [receive_timeout: 15_000]

  @impl Tesla.Adapter
  def call(%Tesla.Env{} = env, opts) do
    opts = Tesla.Adapter.opts(@defaults, env, opts)

    case Keyword.get(opts, :max_body_bytes) do
      max when is_integer(max) and (is_nil(env.body) or is_binary(env.body)) ->
        capped_call(env, opts, max)

      _ ->
        Tesla.Adapter.Finch.call(env, opts)
    end
  end

  defp capped_call(env, opts, max) do
    name = Keyword.fetch!(opts, :name)

    req_opts =
      Keyword.take(opts, [:pool_timeout, :receive_timeout, :request_timeout, :pool_strategy])

    build_opts = Keyword.take(opts, [:unix_socket, :pool_tag])

    req =
      Finch.build(
        format_method(env.method),
        Tesla.build_url(env),
        env.headers,
        env.body,
        build_opts
      )

    acc = %{status: nil, headers: [], chunks: [], size: 0, too_large: false}

    # an answer to HEAD declares the length of a body it does not send
    check_declared? = env.method != :head

    case Finch.stream_while(req, name, acc, &read(&1, &2, max, check_declared?), req_opts) do
      {:ok, %{too_large: true}} ->
        {:error, :body_too_large}

      {:ok, %{status: status, headers: headers, chunks: chunks}} ->
        {:ok,
         %Tesla.Env{
           env
           | status: status,
             headers: headers,
             body: chunks |> Enum.reverse() |> IO.iodata_to_binary()
         }}

      {:error, reason, _acc} ->
        {:error, unwrap_error(reason)}
    end
  end

  defp read({:status, status}, acc, _max, _check_declared?), do: {:cont, %{acc | status: status}}

  defp read({:headers, headers}, acc, max, check_declared?) do
    acc = %{acc | headers: headers}

    if check_declared? and declared_length(headers) > max,
      do: {:halt, %{acc | too_large: true}},
      else: {:cont, acc}
  end

  defp read({:data, data}, %{size: size, chunks: chunks} = acc, max, _check_declared?) do
    size = size + byte_size(data)

    if size > max,
      do: {:halt, %{acc | size: size, chunks: [], too_large: true}},
      else: {:cont, %{acc | size: size, chunks: [data | chunks]}}
  end

  defp read({:trailers, _trailers}, acc, _max, _check_declared?), do: {:cont, acc}

  defp declared_length(headers) do
    with value when is_binary(value) <-
           Enum.find_value(headers, fn {k, v} -> String.downcase(k) == "content-length" && v end),
         {length, _} <- Integer.parse(value) do
      length
    else
      _ -> 0
    end
  end

  defp unwrap_error(error) when is_struct(error, Finch.TransportError), do: error.reason
  defp unwrap_error(error) when is_struct(error, Finch.HTTPError), do: error.source || error
  defp unwrap_error(error), do: error
end
