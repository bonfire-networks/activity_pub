import ActivityPub.Test.Helpers
import ActivityPub.Utils

{:ok, _} = Application.ensure_all_started(:ex_machina)

ExUnit.start(
  exclude: [:skip, :todo, :fixme, :test_instance, :live_federation],
  capture_log: true
)

{:ok, _} = Ecto.Adapters.Postgres.ensure_all_started(repo(), :temporary)

# This cleans up the test database and loads the schema
Mix.Task.run("ecto.create")
Mix.Task.run("ecto.migrate")
# Mix.Task.run("ecto.load")

# Start a process ONLY for our test run.
# {:ok, _pid} = repo().start_link() # already started at this point

Ecto.Adapters.SQL.Sandbox.mode(repo(), :manual)
