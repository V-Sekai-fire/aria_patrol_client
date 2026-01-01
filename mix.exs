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
      # ENet DTLS client for network communication
      {:enet, git: "https://github.com/V-Sekai-fire/elixir-enet.git", branch: "main"},
      # Process registry
      {:gproc, git: "https://github.com/uwiger/gproc.git", branch: "master", override: true},
      # Use aria_patrol_solver for planning
      {:aria_patrol_solver,
       git: "https://github.com/V-Sekai-fire/aria-patrol-solver.git", branch: "main"},
      # JSON encoding for trajectory export
      {:jason, "~> 1.4"},
      # Code analysis
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end

