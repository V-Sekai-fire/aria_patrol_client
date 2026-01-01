defmodule AriaPatrolSolverClient.Application do
  @moduledoc """
  Application supervisor for Aria Patrol Solver Client.
  """
  use Application

  def start(_type, _args) do
    # Ensure required applications are started
    {:ok, _} = Application.ensure_all_started(:spatial_node_store_client)

    children = [
      # Start the patrol client supervisor
      {AriaPatrolSolverClient.PatrolClientSupervisor, []}
    ]

    opts = [strategy: :one_for_one, name: AriaPatrolSolverClient.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

