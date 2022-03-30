defmodule ActivityPub.Common do
  import Where

  def repo, do: ActivityPub.Config.get!(:repo)

  def adapter_fallback() do
    warn("Could not find an ActivityPub adapter, falling back to TestAdapter")

    ActivityPub.TestAdapter
  end
end
