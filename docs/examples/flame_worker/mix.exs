defmodule FlameWorker.MixProject do
  use Mix.Project

  def project do
    [
      app: :flame_worker,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {FlameWorker.Application, []}
    ]
  end

  defp deps do
    [
      {:flame, "~> 0.5"}
    ]
  end

  defp releases do
    [
      flame_worker: [
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
