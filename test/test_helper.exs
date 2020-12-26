{:ok, _} = Application.ensure_all_started(:ex_machina)
ExUnit.start()

{:ok, _} = Ecto.Adapters.Postgres.ensure_all_started(ActivityPub.TestRepo, :temporary)

# This cleans up the test database and loads the schema
Mix.Task.run("ecto.create")
Mix.Task.run("ecto.migrate")
# Mix.Task.run("ecto.load")

# Start a process ONLY for our test run.
{:ok, _pid} = ActivityPub.TestRepo.start_link()

Ecto.Adapters.SQL.Sandbox.mode(ActivityPub.TestRepo, :manual)
