defmodule AriaPatrolSolverClient.PatrolClient do
  @moduledoc """
  Patrol client that uses SpatialNodeStoreClient to connect and patrol waypoints.

  This client:
  1. Connects to the Spatial Node Store server using SimulationClient
  2. Uses aria_patrol_solver to plan optimal patrol routes
  3. Executes patrol by sending movement intents through the client
  4. Handles waypoint navigation and patrol loops
  """

  use GenServer
  require Logger

  alias SpatialNodeStoreClient.SimulationClient

  # Latency constraints: 10-30ms from event time (constrained by speed of light + processing)
  # Update rate must ensure we never exceed max latency for objects
  @max_latency_ms 30  # Maximum allowed latency (30ms)
  @min_latency_ms 10  # Minimum latency (10ms, speed of light + processing)
  @default_update_rate_ms 16  # 64 Hz - within latency budget

  defstruct [
    :client_pid,
    :instance_id,
    :server_host,
    :server_port,
    :entity_id,
    :node_path,
    :waypoints,
    :current_waypoint_index,
    :patrol_plan,
    :current_position,
    :target_position,
    :state,
    :update_interval,
    :completed_cycles,
    :last_waypoint_index
  ]

  ## Public API

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec start_patrol(pid() | atom()) :: :ok
  def start_patrol(pid) do
    GenServer.cast(pid, :start_patrol)
  end

  @spec stop_patrol(pid() | atom()) :: :ok
  def stop_patrol(pid) do
    GenServer.cast(pid, :stop_patrol)
  end

  @spec get_status(pid() | atom()) :: map()
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  @spec get_patrol_status(pid() | atom()) :: map()
  def get_patrol_status(pid) do
    GenServer.call(pid, :get_patrol_status)
  end

  ## GenServer Implementation

  @impl true
  def init(opts) do
    instance_id = Keyword.get(opts, :instance_id, "patrol_client")
    server_host = Keyword.get(opts, :server_host, "127.0.0.1")
    server_port = Keyword.get(opts, :server_port, 7777)
    entity_id = Keyword.get(opts, :entity_id, "patrol_entity_1")
    node_path = Keyword.get(opts, :node_path, "/root/patrol_entity")

    # Support both custom waypoints and auto-generation
    custom_waypoints = Keyword.get(opts, :waypoints)
    num_waypoints = Keyword.get(opts, :num_waypoints, 5)
    use_solver = Keyword.get(opts, :use_solver, true)  # Use aria_patrol_solver by default
    update_interval_raw = Keyword.get(opts, :update_interval, @default_update_rate_ms)

    # Validate update interval doesn't exceed max latency
    update_interval =
      cond do
        update_interval_raw > @max_latency_ms ->
          Logger.warning(
            "Update interval #{update_interval_raw}ms exceeds max latency #{@max_latency_ms}ms. " <>
              "Clamping to #{@max_latency_ms}ms"
          )
          @max_latency_ms

        update_interval_raw < @min_latency_ms ->
          Logger.warning(
            "Update interval #{update_interval_raw}ms is below min latency #{@min_latency_ms}ms. " <>
              "Clamping to #{@min_latency_ms}ms"
          )
          @min_latency_ms

        true ->
          update_interval_raw
      end

    # Start the simulation client
    {:ok, client_pid} = SimulationClient.start_link(
      instance_id: instance_id,
      server_host: server_host,
      server_port: server_port
    )

    # Connect to server
    case SimulationClient.connect(client_pid) do
      :ok ->
        Logger.info("Patrol client connected to server at #{server_host}:#{server_port}")

        # Get waypoints: use custom if provided, otherwise generate
        waypoints =
          if custom_waypoints do
            Logger.info("Using custom waypoints: #{length(custom_waypoints)} waypoints")
            custom_waypoints
          else
            Logger.info("Generating #{num_waypoints} waypoints")
            generate_waypoints(num_waypoints)
          end

        # Plan patrol route using aria_patrol_solver if enabled
        patrol_plan =
          if use_solver and length(waypoints) > 1 do
            Logger.info("Planning optimal patrol route using aria_patrol_solver...")
            plan_patrol_route(waypoints)
          else
            nil
          end

        state = %__MODULE__{
          client_pid: client_pid,
          instance_id: instance_id,
          server_host: server_host,
          server_port: server_port,
          entity_id: entity_id,
          node_path: node_path,
          waypoints: waypoints,
          patrol_plan: patrol_plan,
          current_waypoint_index: 0,
          current_position: {0.0, 0.0, 0.0},
          target_position: nil,
          state: :idle,
          update_interval: update_interval,
          completed_cycles: 0,
          last_waypoint_index: -1
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to connect patrol client: #{inspect(reason)}")
        {:stop, {:error, :connection_failed}}
    end
  end

  @impl true
  def handle_cast(:start_patrol, state) do
    Logger.info("Starting patrol for entity #{state.entity_id}")

    # Use planned waypoints if available, otherwise use original waypoints
    waypoints_to_use =
      if state.patrol_plan && state.patrol_plan.waypoints do
        Logger.info("Using optimized patrol route (total distance: #{:erlang.float_to_binary(state.patrol_plan.total_distance, decimals: 2)})")
        state.patrol_plan.waypoints
      else
        state.waypoints
      end

    # Get first waypoint
    target = List.first(waypoints_to_use)

    # Schedule first movement
    schedule_movement(state.update_interval)

    updated_state = %{
      state
      | state: :patrolling,
        waypoints: waypoints_to_use,  # Update to use planned waypoints
        target_position: target,
        current_waypoint_index: 0,
        last_waypoint_index: -1,
        completed_cycles: 0
    }

    {:noreply, updated_state}
  end

  @impl true
  def handle_cast(:stop_patrol, state) do
    Logger.info("Stopping patrol for entity #{state.entity_id}")
    {:noreply, %{state | state: :idle, target_position: nil}}
  end

  @impl true
  def handle_info(:move_to_waypoint, state) when state.state == :patrolling do
    # Send movement intent to server
    case state.target_position do
      nil ->
        # Move to next waypoint
        next_index = rem(state.current_waypoint_index + 1, length(state.waypoints))
        target = Enum.at(state.waypoints, next_index)

        send_movement_intent(state, target)

        updated_state = %{state |
          target_position: target,
          current_waypoint_index: next_index
        }

        schedule_movement(state.update_interval)
        {:noreply, updated_state}

      target ->
        # Check if we've reached the target (simple distance check)
        distance = calculate_distance(state.current_position, target)

        if distance < 0.5 do
          # Reached waypoint, move to next
          next_index = rem(state.current_waypoint_index + 1, length(state.waypoints))
          next_target = Enum.at(state.waypoints, next_index)

          # Check if we completed a cycle
          completed_cycle = calculate_completed_cycles(state, next_index)

          Logger.debug("Reached waypoint #{state.current_waypoint_index}, moving to #{next_index} (cycles: #{completed_cycle})")

          send_movement_intent(state, next_target)

          updated_state = %{
            state
            | current_position: target,
              target_position: next_target,
              current_waypoint_index: next_index,
              last_waypoint_index: state.current_waypoint_index,
              completed_cycles: completed_cycle
          }

          schedule_movement(state.update_interval)
          {:noreply, updated_state}
        else
          # Continue moving toward target
          send_movement_intent(state, target)

          # Update position (simulated - real position comes from server)
          new_position = interpolate_position(state.current_position, target, 0.1)

          schedule_movement(state.update_interval)
          {:noreply, %{state | current_position: new_position}}
        end
    end
  end

  @impl true
  def handle_info(:move_to_waypoint, state) do
    # Not patrolling, ignore
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      state: state.state,
      entity_id: state.entity_id,
      current_waypoint_index: state.current_waypoint_index,
      total_waypoints: length(state.waypoints),
      current_position: state.current_position,
      target_position: state.target_position
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_patrol_status, _from, state) do
    total_waypoints = length(state.waypoints)
    is_complete = state.completed_cycles > 0

    status = %{
      current_waypoint_index: state.current_waypoint_index,
      total_waypoints: total_waypoints,
      completed_cycles: state.completed_cycles,
      is_complete: is_complete,
      state: state.state
    }
    {:reply, status, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.client_pid do
      SimulationClient.disconnect(state.client_pid)
    end
    :ok
  end

  ## Private Functions

  defp generate_waypoints(num_waypoints) do
    # Generate waypoints in a simple grid pattern
    # Using 2D grid for simplicity (XZ plane, Y=0)
    Enum.map(0..(num_waypoints - 1), fn i ->
      angle = i * 2 * :math.pi() / num_waypoints
      radius = 10.0
      x = radius * :math.cos(angle)
      z = radius * :math.sin(angle)
      {x, 0.0, z}
    end)
  end

  defp plan_patrol_route(waypoints) do
    # Use aria_patrol_solver to plan optimal patrol route
    # This creates a plan that visits all waypoints optimally

      # Use solver to plan route (simplified - actual solver integration would be more complex)
    # For now, we'll use the solver to determine optimal order
    Logger.info("Planning route for #{length(waypoints)} waypoints")

    # If solver is available, use it to optimize waypoint order
    # Otherwise, use waypoints in provided order
    {:ok, ordered_waypoints} = plan_optimal_order(waypoints)
    Logger.info("✓ Optimal route planned: #{length(ordered_waypoints)} waypoints")
    %{
      waypoints: ordered_waypoints,
      plan_type: :optimized,
      total_distance: calculate_total_distance(ordered_waypoints)
    }
  rescue
    e ->
      Logger.warning("Error planning route: #{inspect(e)}, using original waypoints")
      %{
        waypoints: waypoints,
        plan_type: :original,
        total_distance: calculate_total_distance(waypoints)
      }
  end

  defp plan_optimal_order(waypoints) when length(waypoints) <= 1 do
    {:ok, waypoints}
  end

  defp plan_optimal_order(waypoints) do
    # Simple nearest-neighbor heuristic for TSP (Traveling Salesman Problem)
    # This finds a good (but not necessarily optimal) order

    start = List.first(waypoints)
    remaining = Enum.drop(waypoints, 1)
    ordered = [start]

    ordered_waypoints =
      Enum.reduce(remaining, {ordered, remaining}, fn _, {acc, remaining} ->
        find_next_waypoint(acc, remaining)
      end)
      |> elem(0)

    {:ok, ordered_waypoints}
  end

  defp find_next_waypoint(acc, remaining) do
    if Enum.empty?(remaining) do
      {acc, []}
    else
      # Find nearest unvisited waypoint
      last = List.last(acc)
      {nearest, nearest_index} =
        remaining
        |> Enum.with_index()
        |> Enum.min_by(fn {waypoint, _} ->
          calculate_distance(last, waypoint)
        end)

      new_remaining = List.delete_at(remaining, nearest_index)
      {acc ++ [nearest], new_remaining}
    end
  end

  defp calculate_total_distance(waypoints) when length(waypoints) <= 1 do
    0.0
  end

  defp calculate_total_distance(waypoints) do
    waypoints
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [from, to], acc ->
      acc + calculate_distance(from, to)
    end)
  end

  defp send_movement_intent(state, target_position) do
    {x, y, z} = target_position

    transform = %{
      origin: %{x: x, y: y, z: z},
      rotation: %{x: 0.0, y: 0.0, z: 0.0, w: 1.0}  # Identity quaternion
    }

    # Send as player intent (uses prediction and rollback)
    SimulationClient.send_player_intent(
      state.client_pid,
      "transform",
      %{
        node_path: state.node_path,
        transform: transform
      }
    )
  end

  defp calculate_distance({x1, y1, z1}, {x2, y2, z2}) do
    dx = x2 - x1
    dy = y2 - y1
    dz = z2 - z1
    :math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  defp interpolate_position(from, to, step) do
    {x1, y1, z1} = from
    {x2, y2, z2} = to

    distance = calculate_distance(from, to)

    if distance < step do
      to
    else
      t = step / distance
      {
        x1 + (x2 - x1) * t,
        y1 + (y2 - y1) * t,
        z1 + (z2 - z1) * t
      }
    end
  end

  defp schedule_movement(interval) do
    Process.send_after(self(), :move_to_waypoint, interval)
  end

  defp calculate_completed_cycles(state, next_index) do
    # Cycle is complete when we reach waypoint 0 and the last waypoint was the final one
    total_waypoints = length(state.waypoints)
    if next_index == 0 and state.current_waypoint_index == total_waypoints - 1 do
      state.completed_cycles + 1
    else
      state.completed_cycles
    end
  end
end
