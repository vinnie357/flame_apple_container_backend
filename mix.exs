defmodule FlameAppleContainerBackend.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/vinnie357/flame_apple_container_backend"

  def project do
    [
      app: :flame_apple_container_backend,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: [test: :test]]
  end

  def application do
    extra_applications = [:logger]

    extra_applications =
      if Mix.env() == :test, do: extra_applications ++ [:floki], else: extra_applications

    [
      extra_applications: extra_applications,
      mod: {FlameAppleContainerBackend.Application, []}
    ]
  end

  defp description do
    "A FLAME backend for macOS Apple Containers with security, monitoring, orchestration, and an optional web dashboard."
  end

  defp package do
    [
      name: "flame_apple_container_backend",
      maintainers: ["Vinnie Mazza"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "FlameAppleContainerBackend",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

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

      # Documentation
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},

      # Development and testing tools
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:floki, ">= 0.30.0", only: :test},
      {:tidewave, "~> 0.1", only: :dev},
      {:bandit, "~> 1.0", only: :dev}
    ]
  end

  defp aliases do
    [
      tidewave: "run -e 'Bandit.start_link(plug: Tidewave, port: 4000)' --no-halt"
    ]
  end
end
