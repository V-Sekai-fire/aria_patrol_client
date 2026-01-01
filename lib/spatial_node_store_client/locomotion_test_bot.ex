defmodule SpatialNodeStoreClient.LocomotionTestBot do
  @moduledoc """
  Simple locomotion testing bot for MMOG-style movement testing.

  Based on common MMOG testing patterns:
  - Waypoint navigation
  - Patrol routes
  - Random exploration
  - Network synchronization verification

  ## Godot Engine Coordinate Conventions

  This module follows Godot Engine's coordinate system conventions:

  - **Up Direction**: Y-axis (positive Y is up)
  - **Forward Direction**: Negative Z-axis (-Z is forward, +Z is backward)
  - **Right Direction**: X-axis (positive X is right)
  - **Handedness**: Right-handed coordinate system
  - **Quaternion Format**: `%{x: 0.0, y: 0.0, z: 0.0, w: 1.0}` (identity = no rotation)

  All movement calculations use these conventions to ensure compatibility with Godot.
  """

  use GenServer

  defstruct [
    :client_pid,
    :current_position,
    :waypoints,
    :patrol_index,
    :test_mode,
    :test_results
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    client_pid = Keyword.get(opts, :client_pid)
    mode = Keyword.get(opts, :mode, :waypoint)
    start_pos = Keyword.get(opts, :start_position, {0.0, 0.0, 0.0})

    waypoints = case mode do
      :waypoint -> generate_waypoint_test(start_pos)
      :patrol -> generate_patrol_route(start_pos)
      :random -> []
      :stress -> generate_stress_test_waypoints(start_pos)
    end

    schedule_movement(mode)

    {:ok, %__MODULE__{
      client_pid: client_pid,
      current_position: start_pos,
      waypoints: waypoints,
      patrol_index: 0,
      test_mode: mode,
      test_results: []
    }}
  end

  def handle_info(:move, state) do
    {target, new_state} = get_next_target(state)
    intent = generate_movement_intent(state.current_position, target)

    if state.client_pid do
      send(state.client_pid, {:intent, intent})
    end

    # Update position (simulated - real position comes from server)
    new_position = target
    new_results = [%{timestamp: System.monotonic_time(:millisecond), target: target} | state.test_results]

    schedule_movement(new_state.test_mode)

    {:noreply, %{new_state | current_position: new_position, test_results: new_results}}
  end

  # Waypoint navigation test
  # Godot conventions: Y-up, -Z forward, right-handed
  defp generate_waypoint_test(start_pos) do
    # Simple waypoint path: square pattern
    # X = right, Y = up, Z = backward (forward is -Z)
    {x, y, z} = start_pos
    [
      {x + 10.0, y, z},      # Move right
      {x + 10.0, y, z - 10.0},  # Move right + forward (-Z)
      {x, y, z - 10.0},      # Move forward (-Z)
      {x, y, z},             # Return to start
      {x - 10.0, y, z},      # Move left
      {x - 10.0, y, z + 10.0},  # Move left + backward (+Z)
      {x, y, z + 10.0},      # Move backward (+Z)
      {x, y, z}              # Return to start
    ]
  end

  # Patrol route test (common in MMOGs)
  # Godot conventions: Y-up, -Z forward, right-handed
  defp generate_patrol_route(start_pos) do
    {x, y, z} = start_pos
    # Circular patrol (XZ plane, Y-up)
    # Forward is -Z, so we use -sin for forward component
    Enum.map(0..7, fn i ->
      angle = i * :math.pi() / 4
      {x + 15.0 * :math.cos(angle), y, z - 15.0 * :math.sin(angle)}
    end)
  end

  # Stress test: rapid movement
  # Godot conventions: Y-up, -Z forward, right-handed
  defp generate_stress_test_waypoints(start_pos) do
    {x, y, z} = start_pos
    # Many close waypoints for rapid movement testing
    # Grid pattern in XZ plane (Y-up)
    Enum.flat_map(0..4, fn i ->
      Enum.map(0..4, fn j ->
        {x + i * 2.0, y, z - j * 2.0}  # Forward is -Z
      end)
    end)
  end

  defp get_next_target(state) do
    case state.test_mode do
      :waypoint ->
        # Sequential waypoint navigation
        waypoint = Enum.at(state.waypoints, rem(state.patrol_index, length(state.waypoints)))
        new_index = state.patrol_index + 1
        {waypoint, %{state | patrol_index: new_index}}

      :patrol ->
        # Continuous patrol loop
        waypoint = Enum.at(state.waypoints, rem(state.patrol_index, length(state.waypoints)))
        new_index = state.patrol_index + 1
        {waypoint, %{state | patrol_index: new_index}}

      :random ->
        # Random movement within area
        # Godot conventions: Y-up, -Z forward, right-handed
        {x, y, z} = state.current_position
        target = {
          x + (:rand.uniform(20) - 10),  # Random X (right/left)
          y,                              # Keep Y (up) constant
          z - (:rand.uniform(20) - 10)   # Random Z (forward/backward, forward is -Z)
        }
        {target, state}

      :stress ->
        # Rapid sequential movement
        waypoint = Enum.at(state.waypoints, rem(state.patrol_index, length(state.waypoints)))
        new_index = state.patrol_index + 1
        {waypoint, %{state | patrol_index: new_index}}
    end
  end

  defp generate_movement_intent(_from, to) do
    # Simple: teleport to target (isekai style)
    # For actual movement, would calculate velocity vector
    # Godot quaternion format: {x, y, z, w} or %{x, y, z, w}
    # Identity quaternion (no rotation): {0.0, 0.0, 0.0, 1.0}
    {x, y, z} = to
    %{
      intent_type: "transform",
      intent_data: %{
        transform: %{
          origin: %{x: x, y: y, z: z},
          rotation: %{x: 0.0, y: 0.0, z: 0.0, w: 1.0}  # Identity quaternion (Godot format)
        }
      }
    }
  end

  defp schedule_movement(mode) do
    # Movement interval based on test mode
    interval = case mode do
      :stress -> 100  # 10 Hz for stress test
      _ -> 1000       # 1 Hz for normal tests
    end
    Process.send_after(self(), :move, interval)
  end

  # Public API for test results
  def get_results(pid) do
    GenServer.call(pid, :get_results)
  end

  def handle_call(:get_results, _from, state) do
    {:reply, state.test_results, state}
  end
end
