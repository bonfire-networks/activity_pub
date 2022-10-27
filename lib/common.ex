defmodule ActivityPub.Common do
  import Untangle

  def repo, do: (Process.get(:ecto_repo_module) || ActivityPub.Config.get!(:repo)) #|> info

  def adapter_fallback() do
    warn("Could not find an ActivityPub adapter, falling back to TestAdapter")

    ActivityPub.TestAdapter
  end

  def cachex_fetch(cache, key, fallback, options \\ []) when is_function(fallback) do
    p = Process.get()
    Cachex.fetch(cache, key, fn _ ->
      Process.put(:phoenix_endpoint_module, p[:phoenix_endpoint_module])
      Process.put(:ecto_repo_module, p[:ecto_repo_module])

       fallback.()
      end,
      options)
  end

  def ok_unwrap(val, fallback \\ nil)
  def ok_unwrap({:ok, val}, _fallback), do: val
  def ok_unwrap({:error, _val}, fallback), do: fallback
  def ok_unwrap(:error, fallback), do: fallback
  def ok_unwrap(val, fallback), do: val || fallback

end
