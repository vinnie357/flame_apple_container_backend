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
      description: description(),
      package: package(),
      docs: docs(),
      test_coverage: [
        ignore_modules: [FLAME.AppleContainers.CLI.System]
      ],
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: [test: :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "A FLAME backend for macOS Apple Containers."
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
      main: "FLAME.AppleContainersBackend",
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

      # Documentation
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},

      # Development and testing tools
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.0", only: :dev}
    ]
  end
end
