# Aria Patrol Solver Client

A patrol client that connects to the Spatial Node Store system and performs patrol behavior using the client applications.

## Overview

This client:
- Uses `SpatialNodeStoreClient.SimulationClient` to connect to the Spatial Node Store server
- Plans patrol routes (can integrate with aria_patrol_solver for optimal path planning)
- Executes patrol by sending movement intents through the client
- Handles waypoint navigation and continuous patrol loops

## Usage

### Starting a Patrol Client

```elixir
# Start the application
{:ok, _} = AriaPatrolSolverClient.Application.start(:normal, [])

# Start a patrol client with auto-generated waypoints
{:ok, pid} = AriaPatrolSolverClient.PatrolClientSupervisor.start_patrol_client([
  instance_id: "patrol_world",
  server_host: "127.0.0.1",
  server_port: 7777,
  entity_id: "patrol_entity_1",
  node_path: "/root/patrol_entity",
  num_waypoints: 5,
  update_interval: 16  # 64 Hz (within 10-30ms latency budget)
])

# Or start with custom waypoints (uses aria_patrol_solver for optimal route)
{:ok, pid} = AriaPatrolSolverClient.PatrolClientSupervisor.start_patrol_client([
  instance_id: "patrol_world",
  server_host: "127.0.0.1",
  server_port: 7777,
  entity_id: "patrol_entity_1",
  node_path: "/root/patrol_entity",
  waypoints: [{0.0, 0.0, 0.0}, {10.0, 0.0, 10.0}, {5.0, 0.0, 15.0}],  # Custom waypoints
  use_solver: true,  # Enable route optimization (default: true)
  update_interval: 16
])

# Start patrolling
AriaPatrolSolverClient.PatrolClient.start_patrol(pid)

# Check status
status = AriaPatrolSolverClient.PatrolClient.get_status(pid)

# Stop patrolling
AriaPatrolSolverClient.PatrolClient.stop_patrol(pid)
```

## Architecture

- **PatrolClient**: Main GenServer that manages patrol behavior
- **SimulationClient**: Uses the spatial_node_store_client app to connect and send intents
- **Waypoint Navigation**: Moves between waypoints in a circular pattern
- **Movement Intents**: Sends transform intents through the client for server-authoritative movement

## Configuration

- `instance_id`: Instance ID for the client connection
- `server_host`: Server hostname (default: "127.0.0.1")
- `server_port`: Server port (default: 7777)
- `entity_id`: Unique entity identifier
- `node_path`: Scene tree node path for the entity
- `num_waypoints`: Number of waypoints in patrol route (default: 5, ignored if `waypoints` is provided)
- `waypoints`: Custom waypoint positions as list of `{x, y, z}` tuples (optional)
- `use_solver`: Enable aria_patrol_solver for route optimization (default: true)
- `update_interval`: Movement update interval in milliseconds (default: 16ms = 64 Hz)

### Custom Waypoints

You can provide exact waypoint positions:

```elixir
waypoints = [
  {0.0, 0.0, 0.0},      # Waypoint A
  {10.0, 0.0, 10.0},    # Waypoint B
  {5.0, 0.0, 15.0}      # Waypoint C
]

{:ok, pid} = AriaPatrolSolverClient.PatrolClientSupervisor.start_patrol_client([
  waypoints: waypoints,
  use_solver: true  # Optimizes route order for shortest path
])
```

When `use_solver: true`, the client uses aria_patrol_solver to:
- Optimize waypoint order using nearest-neighbor TSP heuristic
- Calculate total patrol distance
- Plan efficient patrol routes

### Latency Constraints

The client enforces latency constraints to ensure real-time performance:

- **Maximum latency**: 30ms (constrained by speed of light + processing)
- **Minimum latency**: 10ms (speed of light + processing minimum)
- **Default update rate**: 16ms (64 Hz) - within latency budget

The `update_interval` is automatically clamped to stay within the 10-30ms latency window. If a value outside this range is provided, a warning is logged and the value is clamped to the nearest valid boundary.

**Note**: These constraints ensure that object updates never exceed the latency budget, maintaining real-time performance for VR and interactive applications.

## Visualization

### GLB Animation Generation

You can generate GLB animations from patrol behavior using the trace generation infrastructure:

```bash
# Generate trace from patrol
mix run scripts/patrol_with_trace.exs \
  --waypoint-a-x 0 --waypoint-a-z 0 \
  --waypoint-b-x 10 --waypoint-b-z 10

# Convert to GLB animation
./scripts/generate_patrol_glb.sh
```

This creates an animated GLB file showing the entity moving along the patrol route. The trace captures scene state at 64 Hz, and the GLB can be viewed in Blender or online GLB viewers.

See **[../../scripts/README_PATROL_TRACE.md](../../scripts/README_PATROL_TRACE.md)** for complete documentation.

