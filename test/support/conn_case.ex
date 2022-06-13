defmodule ActivityPubWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ActivityPubWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate
  import ActivityPub.Test.Helpers

  @repo Application.compile_env(:activity_pub, :test_repo, Application.compile_env(:activity_pub, :repo))

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      # import ActivityPubWeb.ConnCase
      import ActivityPub.Test.Helpers
      import Where

      alias ActivityPubWeb.Router.Helpers, as: Routes

      # The default endpoint for testing
      @endpoint endpoint()
    end
  end

  setup tags do
    Cachex.clear(:ap_actor_cache)
    Cachex.clear(:ap_object_cache)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo())

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(repo(), {:shared, self()})
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
