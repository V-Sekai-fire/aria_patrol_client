defmodule AriaPatrolSolverClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :aria_patrol_solver_client,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AriaPatrolSolverClient.Application, []}
    ]
  end

  defp deps do
    [
      # Use the spatial_node_store_client from the umbrella app
      # Path relative to thirdparty/aria_patrol_solver_client/
      {:spatial_node_store_client, path: "../../apps/spatial_node_store_client"},
      # Use aria_patrol_solver for planning
      {:aria_patrol_solver,
       git: "https://github.com/V-Sekai-fire/aria-patrol-solver.git", ref: "2fa9e22"},
      # JSON encoding for trajectory export
      {:jason, "~> 1.4"}
    ]
  end
end

