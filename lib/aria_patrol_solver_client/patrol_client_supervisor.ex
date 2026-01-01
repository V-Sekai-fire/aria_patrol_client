defmodule AriaPatrolSolverClient.PatrolClientSupervisor do
  @moduledoc """
  Supervisor for patrol client processes.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Dynamic supervisor for patrol clients
      {DynamicSupervisor, name: AriaPatrolSolverClient.PatrolClientDynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Start a new patrol client.
  """
  def start_patrol_client(opts) do
    DynamicSupervisor.start_child(
      AriaPatrolSolverClient.PatrolClientDynamicSupervisor,
      {AriaPatrolSolverClient.PatrolClient, opts}
    )
  end
end
