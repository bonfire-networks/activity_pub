defmodule ActivityPub.Common do
  require Logger

  def repo, do: ActivityPub.Config.get!(:repo)

  def adapter_fallback() do
    Logger.warn("Could not find ActivityPub adapter, falling back to TestAdapter")

    ActivityPub.TestAdapter
  end
end
