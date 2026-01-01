import Config

# Latency constraints: 10-30ms from event time (constrained by speed of light + processing)
# Update rate must ensure we never exceed max latency for objects
# Maximum allowed latency: 30ms
# Minimum latency: 10ms (speed of light + processing)
# Default update rate: 16ms (64 Hz) - within latency budget
# Default entity speed: 2.0 units/second - adjusted to stay within latency window

config :aria_patrol_solver_client,
  default_server_host: "127.0.0.1",
  default_server_port: 7777,
  max_latency_ms: 30,
  min_latency_ms: 10,
  default_update_rate_ms: 16,
  default_entity_speed: 2.0

