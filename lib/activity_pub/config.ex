defmodule ActivityPub.Config do
  defmodule Error do
    defexception [:message]
  end

  def get(key), do: get(key, nil)

  def get([key], default), do: get(key, default)

  def get([parent_key | keys], default) do
    case :activity_pub
         |> Application.get_env(parent_key)
         |> get_in(keys) do
      nil -> default
      any -> any
    end
  end

  def get(key, default) do
    Application.get_env(:activity_pub, key, default)
  end

  def get!(key) do
    value = get(key, nil)

    if value == nil do
      raise(Error, message: "Missing configuration value: #{inspect(key)}")
    else
      value
    end
  end

  def put([key], value), do: put(key, value)

  def put([parent_key | keys], value) do
    parent =
      Application.get_env(:activity_pub, parent_key, [])
      |> put_in(keys, value)

    Application.put_env(:activity_pub, parent_key, parent)
  end

  def put(key, value) do
    Application.put_env(:activity_pub, key, value)
  end

  def delete([key]), do: delete(key)

  def delete([parent_key | keys]) do
    {_, parent} =
      Application.get_env(:activity_pub, parent_key)
      |> get_and_update_in(keys, fn _ -> :pop end)

    Application.put_env(:activity_pub, parent_key, parent)
  end

  def delete(key) do
    Application.delete_env(:activity_pub, key)
  end
end
