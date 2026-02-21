defmodule FlameAppleContainerBackend.MixProject do
  use Mix.Project

  def project do
    [
      app: :flame_apple_container_backend,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: [
        test: :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    extra_applications = [:logger]
    extra_applications = if Mix.env() == :test, do: extra_applications ++ [:floki], else: extra_applications

    [
      extra_applications: extra_applications,
      mod: {FlameAppleContainerBackend.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Core FLAME dependencies
      {:flame, "~> 0.5.2"},
      {:jason, "~> 1.0"},
      {:telemetry, "~> 1.0"},

      # Optional web dependencies
      {:plug_cowboy, "~> 2.6", optional: true},
      {:phoenix, "~> 1.7.0", optional: true},
      {:phoenix_live_view, "~> 0.20.0", optional: true},
      {:phoenix_html, "~> 3.3", optional: true},
      {:phoenix_live_dashboard, "~> 0.8", optional: true},
      {:phoenix_live_reload, "~> 1.2", only: :dev, optional: true},
      {:heroicons, "~> 0.5", optional: true},

      # Optional monitoring dependencies
      {:telemetry_metrics, "~> 0.6", optional: true},
      {:telemetry_poller, "~> 1.0", optional: true},
      {:prometheus_ex, "~> 3.0", optional: true},

      # Optional advanced features
      {:req, "~> 0.5.0", optional: true},
      {:fuse, "~> 2.4", optional: true},
      {:gen_state_machine, "~> 3.0", optional: true},

      # Development and testing tools
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:floki, ">= 0.30.0", only: :test},
      {:tidewave, "~> 0.1", only: :dev},
      {:bandit, "~> 1.0", only: :dev}
    ]
  end
  # Optional: Define aliases for common tasks
  defp aliases do
    [
      tidewave: "run -e 'Bandit.start_link(plug: Tidewave, port: 4000)' --no-halt"
    ]
  end

end
