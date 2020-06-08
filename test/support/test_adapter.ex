defmodule ActivityPub.TestAdapter do
  @behaviour ActivityPub.Adapter

  def maybe_create_remote_actor(_term) do
    :ok
  end

  def handle_activity(_term) do
    :ok
  end
end
