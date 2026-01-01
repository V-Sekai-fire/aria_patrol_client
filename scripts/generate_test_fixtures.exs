#!/usr/bin/env elixir

# Script to solve HDDL problems and generate test fixtures
# Usage: mix run scripts/generate_test_fixtures.exs

alias AriaPatrolSolver.Solver
alias AriaPlanner.HDDL, as: PlannerHDDL
alias AriaCore.Plan
alias AriaCore.PlanningDomain

require Logger

defmodule FixtureGenerator do
  @moduledoc """
  Generates test fixtures by solving HDDL problems.
  """

  # Problems to solve
  @problems [
    "test_patrol_plan",
    "test_import_plan",
    "test_roundtrip_plan"
  ]

  def run do
    IO.puts("=" <> String.duplicate("=", 80))
    IO.puts("Generating test fixtures from HDDL problems and domains")
    IO.puts("=" <> String.duplicate("=", 80))
    IO.puts("")

    # Ensure fixture directory exists
    fixture_dir = Path.join([File.cwd!(), "test", "fixtures"])
    File.mkdir_p!(fixture_dir)

    # Get HDDL directory from priv
    hddl_dir = Path.join([File.cwd!(), "priv", "hddl"])

    # Process each problem
    results =
      Enum.map(@problems, fn problem_name ->
        IO.puts("Processing problem: #{problem_name}")
        IO.puts("-" <> String.duplicate("-", 80))

        problem_path = Path.join([hddl_dir, "problems", "#{problem_name}.hddl"])

        if File.exists?(problem_path) do
          case process_problem(problem_path, problem_name, hddl_dir) do
            {:ok, result} ->
              save_fixture(fixture_dir, problem_name, result)
              IO.puts("✓ Generated fixture for #{problem_name}")
              IO.puts("")
              {:ok, problem_name}

            {:error, reason} ->
              IO.puts("✗ Failed to process #{problem_name}: #{inspect(reason)}")
              IO.puts("")
              {:error, problem_name, reason}
          end
        else
          IO.puts("✗ Problem file not found: #{problem_path}")
          IO.puts("")
          {:error, problem_name, :file_not_found}
        end
      end)

    # Also save domain fixtures
    save_domain_fixtures(fixture_dir, hddl_dir)

    IO.puts("=" <> String.duplicate("=", 80))
    IO.puts("Fixture generation complete!")
    IO.puts("=" <> String.duplicate("=", 80))

    # Summary
    successful = Enum.count(results, fn r -> match?({:ok, _}, r) end)
    failed = Enum.count(results, fn r -> match?({:error, _, _}, r) end)

    IO.puts("")
    IO.puts("Summary:")
    IO.puts("  Successful: #{successful}")
    IO.puts("  Failed: #{failed}")
  end

  defp process_problem(problem_path, problem_name, hddl_dir) do
    try do
      # Load problem from HDDL
      case PlannerHDDL.import_from_file(problem_path) do
        {:ok, %Plan{} = plan} ->
          IO.puts("  Loaded plan: #{plan.name}")
          IO.puts("  Plan ID: #{plan.id}")

          # Determine domain based on problem
          domain_name = determine_domain(problem_name)
          domain_path = Path.join([hddl_dir, "domains", "#{domain_name}.hddl"])

          domain_data =
            if File.exists?(domain_path) do
              IO.puts("  Loading domain: #{domain_name}")

              case PlannerHDDL.import_from_file(domain_path) do
                {:ok, %PlanningDomain{} = domain} ->
                  IO.puts("  ✓ Domain loaded successfully")
                  domain_to_map(domain)

                {:error, reason} ->
                  IO.puts("  ✗ Failed to load domain: #{inspect(reason)}")
                  %{error: "Failed to load domain: #{inspect(reason)}"}
              end
            else
              IO.puts("  ✗ Domain file not found: #{domain_path}")
              %{error: "Domain file not found"}
            end

          # Try to solve using the solver with default parameters
          # This will create a basic solution structure
          solution_result =
            try do
              # Use solver with minimal waypoints for testing
              case Solver.solve(
                     num_waypoints: 5,
                     maze_mode: domain_name == "locomotion_maze",
                     grid_width: 10,
                     grid_height: 10,
                     entity_speed: 2.0
                   ) do
                {:ok, solver_result} ->
                  IO.puts("  ✓ Solver completed successfully")
                  %{
                    solver_success: true,
                    num_waypoints: solver_result.num_waypoints,
                    optimized_sequence: solver_result.optimized_sequence,
                    total_distance: solver_result.total_distance,
                    output_path: solver_result.output_path
                  }

                {:error, reason} ->
                  IO.puts("  ✗ Solver failed: #{inspect(reason)}")
                  %{solver_success: false, error: inspect(reason)}
              end
            rescue
              e ->
                IO.puts("  ✗ Solver exception: #{inspect(e)}")
                %{solver_success: false, error: inspect(e)}
            end

          result = %{
            problem_name: problem_name,
            plan_id: plan.id,
            plan_name: plan.name,
            domain_name: domain_name,
            domain_path: domain_path,
            problem_path: problem_path,
            plan: plan_to_map(plan),
            domain: domain_data,
            solution: solution_result,
            generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
          }

          {:ok, result}

        {:error, reason} ->
          {:error, "Failed to import HDDL: #{inspect(reason)}"}
      end
    rescue
      e ->
        {:error, "Exception: #{inspect(e)}"}
    end
  end

  defp determine_domain(problem_name) do
    # Default to maze domain for most problems
    case problem_name do
      name when name in ["test_patrol_plan", "test_roundtrip_plan"] ->
        "locomotion_maze"

      "test_import_plan" ->
        "locomotion_3d"

      _ ->
        "locomotion_maze"
    end
  end

  defp plan_to_map(%Plan{} = plan) do
    %{
      id: plan.id,
      name: plan.name,
      persona_id: plan.persona_id,
      domain_type: plan.domain_type,
      execution_status: plan.execution_status,
      success_probability: plan.success_probability,
      objectives: plan.objectives,
      entity_capabilities: plan.entity_capabilities,
      constraints: plan.constraints,
      temporal_constraints: plan.temporal_constraints
    }
  end

  defp domain_to_map(%PlanningDomain{} = domain) do
    %{
      id: domain.id,
      name: domain.name,
      description: domain.description,
      domain_type: domain.domain_type,
      state: domain.state,
      version: domain.version,
      entities: domain.entities,
      tasks: domain.tasks,
      actions: Enum.map(domain.actions || [], &action_to_map/1),
      commands: Enum.map(domain.commands || [], &action_to_map/1),
      multigoals: Enum.map(domain.multigoals || [], &multigoal_to_map/1),
      metadata: domain.metadata
    }
  end

  defp action_to_map(action) when is_map(action) do
    %{
      id: Map.get(action, :id),
      name: Map.get(action, :name),
      parameters: Map.get(action, :parameters, []),
      precondition: Map.get(action, :precondition),
      effect: Map.get(action, :effect),
      duration: Map.get(action, :duration),
      temporal_metadata: Map.get(action, :temporal_metadata)
    }
  end

  defp multigoal_to_map(multigoal) when is_map(multigoal) do
    %{
      goals: Map.get(multigoal, :goals),
      decomposition: Map.get(multigoal, :decomposition)
    }
  end

  defp save_fixture(fixture_dir, problem_name, result) do
    fixture_path = Path.join([fixture_dir, "#{problem_name}_fixture.json"])
    # Convert tuples to lists for JSON encoding
    sanitized_result = sanitize_for_json(result)
    json_content = Jason.encode!(sanitized_result, pretty: true)
    File.write!(fixture_path, json_content)
  end

  defp sanitize_for_json(data) when is_tuple(data) do
    data |> Tuple.to_list() |> Enum.map(&sanitize_for_json/1)
  end

  defp sanitize_for_json(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> sanitize_for_json()
  end

  defp sanitize_for_json(data) when is_list(data) do
    Enum.map(data, &sanitize_for_json/1)
  end

  defp sanitize_for_json(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} -> {k, sanitize_for_json(v)} end)
    |> Map.new()
  end

  defp sanitize_for_json(data), do: data

  defp save_domain_fixtures(fixture_dir, hddl_dir) do
    IO.puts("")
    IO.puts("Saving domain fixtures...")
    IO.puts("-" <> String.duplicate("-", 80))

    domains = ["locomotion_maze", "locomotion_3d"]

    Enum.each(domains, fn domain_name ->
      domain_path = Path.join([hddl_dir, "domains", "#{domain_name}.hddl"])

      if File.exists?(domain_path) do
        case PlannerHDDL.import_from_file(domain_path) do
          {:ok, %PlanningDomain{} = domain} ->
            domain_map = domain_to_map(domain)
            domain_result = %{
              domain_name: domain_name,
              domain_path: domain_path,
              domain: domain_map,
              generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }

            fixture_path = Path.join([fixture_dir, "#{domain_name}_domain_fixture.json"])
            sanitized_result = sanitize_for_json(domain_result)
            json_content = Jason.encode!(sanitized_result, pretty: true)
            File.write!(fixture_path, json_content)
            IO.puts("✓ Saved domain fixture: #{domain_name}")

          {:error, reason} ->
            IO.puts("✗ Failed to load domain #{domain_name}: #{inspect(reason)}")
        end
      else
        IO.puts("✗ Domain file not found: #{domain_path}")
      end
    end)
  end
end

# Run the generator
FixtureGenerator.run()
