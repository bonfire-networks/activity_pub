defmodule ActivityPub.Common do
  def repo, do: ActivityPub.Config.get!(:repo)
end
