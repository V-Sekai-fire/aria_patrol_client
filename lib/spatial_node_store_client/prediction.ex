
defmodule SpatialNodeStoreClient.Prediction do
  @moduledoc """
  Prediction module for client-side simulation.

  Provides deterministic prediction of player state based on intents.
  Supports rollback and re-simulation when server corrections arrive.
  """

  @doc """
  Predicts new state from intent and current state.

  ## Parameters
  - `intent` - The intent to apply (contains intent_type and intent_data)
  - `current_state` - Current predicted state

  ## Returns
  - New predicted state after applying the intent
  """
  def predict(intent, current_state) do
    apply_intent(intent, current_state)
  end

  @doc """
  Applies an intent to state (deterministic).

  This function must be deterministic - same intent + same state = same result.
  This is critical for rollback to work correctly.

  ## Parameters
  - `intent` - The intent to apply (map with :intent_type and :intent_data)
  - `state` - Current state to apply intent to

  ## Returns
  - New state after applying the intent
  """
  def apply_intent(intent, state) do
    intent_type = Map.get(intent, :intent_type) || Map.get(intent, "intent_type")
    intent_data = Map.get(intent, :intent_data) || Map.get(intent, "intent_data")

    case intent_type do
      "move" ->
        apply_move_intent(intent_data, state)

      "transform" ->
        apply_transform_intent(intent_data, state)

      "jump" ->
        apply_jump_intent(intent_data, state)

      "interact" ->
        apply_interact_intent(intent_data, state)

      _ ->
        # Unknown intent type, return state unchanged
        state
    end
  end

  @doc """
  Compares predicted state vs authoritative state and determines if correction is needed.

  ## Parameters
  - `predicted_state` - Locally predicted state
  - `authoritative_state` - State from server
  - `tolerance` - Tolerance for differences (default: 0.01)

  ## Returns
  - `{:ok, state}` if states match (within tolerance)
  - `{:correction, authoritative_state}` if correction needed
  """
  def reconcile(predicted_state, authoritative_state, tolerance \\ 0.01) do
    # Compare transforms (position and rotation)
    predicted_transform = Map.get(predicted_state, :transform) || Map.get(predicted_state, "transform")
    authoritative_transform = Map.get(authoritative_state, :transform) || Map.get(authoritative_state, "transform")

    if transforms_match?(predicted_transform, authoritative_transform, tolerance) do
      {:ok, predicted_state}
    else
      {:correction, authoritative_state}
    end
  end

  # Private helper functions for applying different intent types

  defp apply_move_intent(intent_data, state) do
    # Extract movement vector from intent_data
    movement = Map.get(intent_data, :movement) || Map.get(intent_data, "movement") || {0.0, 0.0, 0.0}
    delta_time = Map.get(intent_data, :delta_time) || Map.get(intent_data, "delta_time") || 0.016

    # Get current transform
    current_transform = Map.get(state, :transform) || Map.get(state, "transform") || %{
      origin: {0.0, 0.0, 0.0},
      basis: {{1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}}
    }

    # Apply movement to position
    {x, y, z} = Map.get(current_transform, :origin) || Map.get(current_transform, "origin") || {0.0, 0.0, 0.0}
    {dx, dy, dz} = movement

    new_origin = {
      x + dx * delta_time,
      y + dy * delta_time,
      z + dz * delta_time
    }

    new_transform = Map.put(current_transform, :origin, new_origin)
      |> Map.put("origin", new_origin)

    Map.put(state, :transform, new_transform)
      |> Map.put("transform", new_transform)
  end

  defp apply_transform_intent(intent_data, state) do
    # Extract transform from intent_data
    transform = Map.get(intent_data, :transform) || Map.get(intent_data, "transform")

    if transform do
      Map.put(state, :transform, transform)
        |> Map.put("transform", transform)
    else
      state
    end
  end

  defp apply_jump_intent(_intent_data, state) do
    # Simple jump: add vertical velocity
    # In a full implementation, this would apply physics
    current_transform = Map.get(state, :transform) || Map.get(state, "transform") || %{
      origin: {0.0, 0.0, 0.0},
      basis: {{1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}}
    }

    {x, y, z} = Map.get(current_transform, :origin) || Map.get(current_transform, "origin") || {0.0, 0.0, 0.0}
    # Simple jump: add small vertical offset (would be velocity-based in full implementation)
    new_origin = {x, y + 0.1, z}

    new_transform = Map.put(current_transform, :origin, new_origin)
      |> Map.put("origin", new_origin)

    Map.put(state, :transform, new_transform)
      |> Map.put("transform", new_transform)
  end

  defp apply_interact_intent(_intent_data, state) do
    # Interaction intents don't change player state directly
    # They trigger interactions with other objects
    state
  end

  defp transforms_match?(predicted, authoritative, _tolerance) when is_nil(predicted) or is_nil(authoritative) do
    false
  end

  defp transforms_match?(predicted, authoritative, tolerance) do
    pred_origin = Map.get(predicted, :origin) || Map.get(predicted, "origin")
    auth_origin = Map.get(authoritative, :origin) || Map.get(authoritative, "origin")

    if pred_origin && auth_origin do
      {px, py, pz} = pred_origin
      {ax, ay, az} = auth_origin

      dx = abs(px - ax)
      dy = abs(py - ay)
      dz = abs(pz - az)

      # Check if all differences are within tolerance
      dx < tolerance && dy < tolerance && dz < tolerance
    else
      false
    end
  end
end
