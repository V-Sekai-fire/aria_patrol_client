defmodule SpatialNodeStoreClient.IntentBuffer do
  @moduledoc """
  Intent buffer for client-side prediction.

  Stores the last N intents (default: 10) for rollback and re-simulation.
  Intents are generalized player actions (e.g., movement, interactions) rather than raw input data.

  Each intent contains:
  - sequence_number - Monotonically increasing sequence
  - intent_type - Type of intent (e.g., "move", "jump", "interact", "transform")
  - intent_data - Intent-specific data (e.g., movement vector, transform, interaction target)
  - timestamp - Intent timestamp
  - delta_time - Time since last intent
  """

  defstruct intents: [], max_size: 10

  @type intent :: %{
    sequence: non_neg_integer(),
    intent_type: String.t(),
    intent_data: map(),
    timestamp: non_neg_integer(),
    delta_time: float()
  }

  @type t :: %__MODULE__{
    intents: [intent()],
    max_size: non_neg_integer()
  }

  @doc """
  Creates a new intent buffer.
  """
  def new(max_size \\ 10) do
    %__MODULE__{max_size: max_size}
  end

  @doc """
  Adds a new intent to the buffer, maintaining max size.

  ## Parameters
  - `buffer` - The intent buffer
  - `sequence` - Sequence number for this intent
  - `intent_type` - Type of intent (e.g., "move", "transform", "jump", "interact")
  - `intent_data` - Intent-specific data (e.g., movement vector, transform, interaction target)
  - `timestamp` - Intent timestamp (milliseconds)

  ## Returns
  - Updated buffer with new intent added
  """
  def add_intent(buffer, sequence, intent_type, intent_data, timestamp) do
    # Calculate delta_time from previous intent
    delta_time = calculate_delta_time(buffer.intents, timestamp)

    new_intent = %{
      sequence: sequence,
      intent_type: intent_type,
      intent_data: intent_data,
      timestamp: timestamp,
      delta_time: delta_time
    }

    # Add new intent and maintain max size
    updated_intents = [new_intent | buffer.intents]
      |> Enum.take(buffer.max_size)

    %{buffer | intents: updated_intents}
  end

  @doc """
  Gets all intents since a given sequence number (for re-simulation).

  ## Parameters
  - `buffer` - The intent buffer
  - `sequence` - Sequence number to get intents since

  ## Returns
  - List of intents with sequence >= given sequence, in chronological order
  """
  def get_intents_since(buffer, sequence) do
    buffer.intents
      |> Enum.filter(fn intent -> intent.sequence >= sequence end)
      |> Enum.reverse()  # Return in chronological order (oldest first)
  end

  @doc """
  Gets the most recent intent.

  ## Parameters
  - `buffer` - The intent buffer

  ## Returns
  - Most recent intent, or `nil` if buffer is empty
  """
  def get_latest(buffer) do
    List.first(buffer.intents)
  end

  # Private helper functions

  defp calculate_delta_time([], _timestamp), do: 0.0

  defp calculate_delta_time([latest | _], timestamp) do
    delta_ms = timestamp - latest.timestamp
    delta_ms / 1000.0  # Convert to seconds
  end
end

