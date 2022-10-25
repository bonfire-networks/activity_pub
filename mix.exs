defmodule ActivityPub.MixProject do
  use Mix.Project

  def project do
    [
      name: "ActivityPub library",
      app: :activity_pub,
      version: "0.1.0",
      elixir: "~> 1.11",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      licenses: ["GNU AGPLv3"],
      source_url: "https://github.com/bonfire-networks/activity_pub",
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGES.md"]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ActivityPub.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.6.6"},
      {:phoenix_ecto, "~> 4.4"},
      {:ecto_sql, "~> 3.8"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_live_dashboard, "~> 0.7.0"},
      {:telemetry_metrics, "~> 0.4"},
      {:telemetry_poller, "~> 0.4"},
      {:jason, "~> 1.0"},
      {:plug_cowboy, "~> 2.0"},
      {:mime, "~> 2.0.3"},
      {:oban, "~> 2.13.3"},
      {:hackney, "~> 1.16"},
      {:tesla, "~> 1.2"},
      {:http_signatures,
       git: "https://github.com/bonfire-networks/http_signatures",
       branch: "master"},
      {:timex, "~> 3.5"},
      {:cachex, "~> 3.2"},
      {:ex_machina, "~> 2.7", only: [:dev, :test]},
      {:mock, "~> 0.3.0", only: :test},
      {:excoveralls, "~> 0.10", only: :test},
      {
        :pointers_ulid,
        # "~> 0.2"
        git: "https://github.com/bonfire-networks/pointers_ulid", branch: "main"
      },
      # {:pointers,
      #   #"~> 0.5"
      #   git: "https://github.com/bonfire-networks/pointers", branch: "main",
      #   optional: true
      # },
      {:ex_doc, "~> 0.22", only: [:dev, :test], runtime: false},
      {:arrows,
       git: "https://github.com/bonfire-networks/arrows", branch: "main"},
      {:untangle,
       git: "https://github.com/bonfire-networks/untangle", branch: "main"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end
end
