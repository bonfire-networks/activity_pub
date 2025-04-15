defmodule ActivityPub.Web.ConnCase do
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
  by setting `use ActivityPub.Web.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate
  import ActivityPub.Test.Helpers
  import ActivityPub.Utils

  using do
    quote do
      import ActivityPub.Utils
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      # import ActivityPub.Web.ConnCase
      import ActivityPub.Test.Helpers
      import Untangle

      alias ActivityPub.Web.Router.Helpers, as: Routes

      # The default endpoint for testing
      @endpoint endpoint()

      alias ActivityPub.Utils
      alias ActivityPub.Object
      alias ActivityPub.Test.HttpRequestMock
      alias ActivityPub.Tests.ObanHelpers

      @moduletag :ap_lib
    end
  end

  setup tags do
    ActivityPub.Utils.cache_clear()

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo())

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(repo(), {:shared, self()})
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
