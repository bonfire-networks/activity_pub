defmodule ActivityPub.SharedDataCase do
  use ExUnit.CaseTemplate
  import ActivityPub.Utils
  import ActivityPub.Factory
  import Tesla.Mock
  import Untangle
  alias ActivityPub.Object

  setup_all tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo())
    # we are setting :auto here so that the data persists for all tests,
    # normally (with :shared mode) every process runs in a transaction
    # and rolls back when it exits. setup_all runs in a distinct process
    # from each test so the data doesn't exist for each test.
    Ecto.Adapters.SQL.Sandbox.mode(repo(), :auto)

    actor1 = insert(:actor)
    # |> cached_or_handle()

    actor2 = insert(:actor)
    # |> cached_or_handle()

    u1 = "https://mastodon.local/pub/actors/#{actor1.data["preferredUsername"]}/inbox" |> info()
    u2 = "https://mastodon.local/pub/actors/#{actor2.data["preferredUsername"]}/inbox"

    mock(fn
      %{method: :post, url: ^u1} ->
        %Tesla.Env{status: 200}

      %{method: :post, url: ^u2} ->
        %Tesla.Env{status: 200}

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    on_exit(fn ->
      # this callback needs to checkout its own connection since it
      # runs in its own process
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo())
      Ecto.Adapters.SQL.Sandbox.mode(repo(), :auto)

      Object.delete(actor1)
      Object.delete(actor2)
      :ok
    end)

    [
      actor1: actor1,
      actor2: actor2
    ]
  end
end
