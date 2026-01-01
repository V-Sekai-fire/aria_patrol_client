defmodule Mix.Tasks.Test.Locomotion do
  @moduledoc """
  Test locomotion system with automated bot.

  ## Examples

      mix test.locomotion
      mix test.locomotion --mode waypoint
      mix test.locomotion --mode patrol
      mix test.locomotion --mode random
      mix test.locomotion --mode stress
  """

  use Mix.Task

  @shortdoc "Test locomotion with automated bot"

  def run(args) do
    Mix.Task.run("app.start")

    opts = parse_args(args)
    mode = Keyword.get(opts, :mode, :waypoint)

    IO.puts("=" <> String.duplicate("=", 79))
    IO.puts("Locomotion Test Bot - Mode: #{mode}")
    IO.puts("=" <> String.duplicate("=", 79))
    IO.puts("")

    # Start test bot
    {:ok, bot_pid} = SpatialNodeStoreClient.LocomotionTestBot.start_link(
      mode: mode,
      start_position: {0.0, 0.0, 0.0}
    )

    # Run test for 5 seconds (shorter for testing)
    Process.sleep(5_000)

    # Get results
    results = SpatialNodeStoreClient.LocomotionTestBot.get_results(bot_pid)

    IO.puts("Test Results:")
    IO.puts("  Total movements: #{length(results)}")
    IO.puts("  Movements per second: #{length(results) / 5.0 |> Float.round(2)}")
    IO.puts("")
    IO.puts("Sample movements:")
    Enum.take(results, 5) |> Enum.each(fn result ->
      IO.puts("  Target: #{inspect(result.target)}")
    end)

    GenServer.stop(bot_pid)
  end

  defp parse_args(args) do
    {opts, _, _} = OptionParser.parse(args,
      switches: [mode: :string],
      aliases: [m: :mode]
    )

    mode = case Keyword.get(opts, :mode, "waypoint") do
      "waypoint" -> :waypoint
      "patrol" -> :patrol
      "random" -> :random
      "stress" -> :stress
      _ -> :waypoint
    end

    [mode: mode]
  end
end

