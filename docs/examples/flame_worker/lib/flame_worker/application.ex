defmodule FlameWorker.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {FLAME.Terminator,
       name: FLAME.Terminator,
       log: :info,
       child_placement_sup: FlameWorker.ChildPlacementSup},
      {DynamicSupervisor, name: FlameWorker.ChildPlacementSup, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: FlameWorker.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
