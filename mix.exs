defmodule ActivityPub.MixProject do
  use Mix.Project

  def project do
    if System.get_env("AS_UMBRELLA") == "1" do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
    ++
    [
      name: "ActivityPub library",
      app: :activity_pub,
      version: "0.1.0",
      elixir: "~> 1.11",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers(),
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
      {:phoenix, "~> 1.7", optional: true},
      {:plug_cowboy, "~> 2.0", optional: true},
      {:phoenix_ecto, "~> 4.5", optional: true},
      {:phoenix_live_dashboard, "~> 0.8.0", optional: true},
      {:phoenix_html_helpers, "~> 1.0"},
      {:ecto_sql, "~> 3.8"},
      {:postgrex, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.0"},
      {:mime, "~> 2.0.3"},
      {:oban, "~> 2.17"},
      # {:hackney, "~> 1.16"},
      {:tesla, "~> 1.2"},
      # {:tesla_extra, "~> 0.2"},
      {:http_signatures,
       git: "https://github.com/bonfire-networks/http_signatures"},
      {:mfm_parser, git: "https://akkoma.dev/AkkomaGang/mfm-parser.git", optional: true},
      {:remote_ip, "~> 1.1"},
      {:hammer_plug, "~> 3.0"},
      {:timex, "~> 3.5"},
      {:cachex, "~> 4.0"},
      {:ex_machina, "~> 2.7", only: [:dev, :test]},
      {:mock, "~> 0.3.0", only: :test},
      {:excoveralls, "~> 0.10", only: :test},
      {:plug_http_validator, git: "https://github.com/bonfire-networks/plug_http_validator", branch: "pr-naive-datetime"},
      {
        :needle_uid,
        # "~> 0.1"
        git: "https://github.com/bonfire-networks/needle_uid",
      },
      # {:needle,
      #   #"~> 0.5"
      #   git: "https://github.com/bonfire-networks/needle", 
      #   optional: true
      # },
      {:ex_doc, "~> 0.22", only: [:dev, :test], runtime: false},
      {:arrows, "~> 0.2"},
      {:untangle, "~> 0.3"}
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
