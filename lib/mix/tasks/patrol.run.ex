defmodule Mix.Tasks.Patrol.Run do
  @moduledoc """
  Run a patrol client that connects to the Spatial Node Store and patrols waypoints.

  ## Examples

      mix patrol.run
      mix patrol.run --server-host 127.0.0.1 --server-port 7777
      mix patrol.run --num-waypoints 10
  """
  use Mix.Task

  @shortdoc "Run patrol client"
  @requirements ["app.config"]

  @switches [
    server_host: :string,
    server_port: :integer,
    instance_id: :string,
    entity_id: :string,
    node_path: :string,
    num_waypoints: :integer,
    update_interval: :integer
  ]

  @aliases [
    h: :server_host,
    p: :server_port,
    n: :num_waypoints
  ]

  def run(args) do
    {opts, _argv, _errors} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    server_host = Keyword.get(opts, :server_host, "127.0.0.1")
    server_port = Keyword.get(opts, :server_port, 7777)
    instance_id = Keyword.get(opts, :instance_id, "patrol_world")
    entity_id = Keyword.get(opts, :entity_id, "patrol_entity_1")
    node_path = Keyword.get(opts, :node_path, "/root/patrol_entity")
    num_waypoints = Keyword.get(opts, :num_waypoints, 5)
    update_interval = Keyword.get(opts, :update_interval, 16)

    require Logger
    Logger.info("Starting patrol client...")
    Logger.info("  Server: #{server_host}:#{server_port}")
    Logger.info("  Instance: #{instance_id}")
    Logger.info("  Entity: #{entity_id}")
    Logger.info("  Waypoints: #{num_waypoints}")
    Logger.info("  Update rate: #{update_interval}ms")

    # Start the application
    {:ok, _} = Application.ensure_all_started(:aria_patrol_solver_client)

    # Start patrol client
    case AriaPatrolSolverClient.PatrolClientSupervisor.start_patrol_client([
      instance_id: instance_id,
      server_host: server_host,
      server_port: server_port,
      entity_id: entity_id,
      node_path: node_path,
      num_waypoints: num_waypoints,
      update_interval: update_interval
    ]) do
      {:ok, pid} ->
        Logger.info("Patrol client started with PID: #{inspect(pid)}")

        # Start patrolling
        AriaPatrolSolverClient.PatrolClient.start_patrol(pid)

        Logger.info("Patrol started. Press Ctrl+C to stop.")

        # Keep running
        Process.sleep(:infinity)

      {:error, reason} ->
        Logger.error("Failed to start patrol client: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
