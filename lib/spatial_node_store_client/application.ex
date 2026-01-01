defmodule SpatialNodeStoreClient.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Ensure gproc and enet are started (required for ENet client)
    Application.ensure_all_started(:gproc)
    Application.ensure_all_started(:enet)

    children = []

    opts = [strategy: :one_for_one, name: SpatialNodeStoreClient.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
