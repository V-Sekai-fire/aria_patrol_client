defmodule SpatialNodeStoreClient.SimulationClient do
  @moduledoc """
  ENet DTLS client for connecting to Spatial Node Store server.

  Handles:
  - Meta-game operations (matchmaking, auth, persistence) via Channel 0 (reliable)
  - Intent-based prediction flow with rollback
  - Simulation relay (add_scene_node, update_node_transform, etc.) via Channel 1 (unreliable)

  ## Usage

      {:ok, pid} = SpatialNodeStoreClient.SimulationClient.start_link(
        instance_id: "test_world",
        server_host: "127.0.0.1",
        server_port: 7777
      )

      :ok = SpatialNodeStoreClient.SimulationClient.connect(pid)

      # Meta-game: Find session
      SpatialNodeStoreClient.SimulationClient.find_session(pid, %{
        world_type: "social_space",
        max_players: 20
      })

      # Simulation: Update node transform (Intent-based with prediction)
      SpatialNodeStoreClient.SimulationClient.update_node_transform(
        pid,
        "/root/avatar_1",
        %{origin: {10.0, 5.0, 0.0}, basis: {{1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}}}
      )
  """

  use GenServer
  require Logger

  @default_channel_count 3
  # Reliable channel for meta-game operations
  @meta_game_channel 0
  # Unreliable channel for simulation updates
  @simulation_channel 1
  @connection_timeout_ms 5000

  ## Public API

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    instance_id = Keyword.get(opts, :instance_id, "default")
    server_host = Keyword.get(opts, :server_host, "127.0.0.1")
    server_port = Keyword.get(opts, :server_port, 7777)

    name = via_tuple(instance_id)

    callback_pid = Keyword.get(opts, :callback_pid, nil)

    GenServer.start_link(
      __MODULE__,
      %{
        instance_id: instance_id,
        server_host: server_host,
        server_port: server_port,
        state: :disconnected,
        enet_host: nil,
        peer_pid: nil,
        meta_game_channel: nil,
        simulation_channel: nil,
        intent_buffer: SpatialNodeStoreClient.IntentBuffer.new(),
        sequence: 0,
        predicted_state: %{},
        pending_requests: %{},
        callback_pid: callback_pid
      },
      name: name
    )
  end

  @spec connect(pid() | atom()) :: :ok | {:error, term()}
  def connect(client_pid) do
    GenServer.call(client_pid, :connect, @connection_timeout_ms)
  end

  @spec disconnect(pid() | atom()) :: :ok
  def disconnect(client_pid) do
    GenServer.call(client_pid, :disconnect)
  end

  @spec find_session(pid() | atom(), map()) :: :ok | {:error, term()}
  def find_session(client_pid, criteria) do
    GenServer.call(client_pid, {:find_session, criteria})
  end

  @spec authenticate(pid() | atom(), String.t(), String.t()) :: :ok | {:error, term()}
  def authenticate(client_pid, user_id, token) do
    GenServer.call(client_pid, {:authenticate, user_id, token})
  end

  @spec join_session(pid() | atom(), String.t()) :: :ok | {:error, term()}
  def join_session(client_pid, session_id) do
    GenServer.call(client_pid, {:join_session, session_id})
  end

  @spec leave_session(pid() | atom()) :: :ok
  def leave_session(client_pid) do
    GenServer.call(client_pid, :leave_session)
  end

  @spec request_scene_tree_snapshot(pid() | atom()) :: :ok | {:error, term()}
  def request_scene_tree_snapshot(client_pid) do
    GenServer.call(client_pid, :request_scene_tree_snapshot)
  end

  @spec update_node_transform(pid() | atom(), String.t(), map()) :: :ok
  def update_node_transform(client_pid, node_path, transform) do
    GenServer.cast(client_pid, {:update_node_transform, node_path, transform})
  end

  @spec add_scene_node(pid() | atom(), String.t(), map()) :: :ok
  def add_scene_node(client_pid, node_path, node_data) do
    GenServer.cast(client_pid, {:add_scene_node, node_path, node_data})
  end

  @spec remove_scene_node(pid() | atom(), String.t()) :: :ok
  def remove_scene_node(client_pid, node_path) do
    GenServer.cast(client_pid, {:remove_scene_node, node_path})
  end

  @spec send_player_intent(pid() | atom(), String.t(), map()) :: :ok
  def send_player_intent(client_pid, intent_type, intent_data) do
    GenServer.cast(client_pid, {:send_player_intent, intent_type, intent_data})
  end

  @spec send_multiplayer_sync_request(pid() | atom(), String.t()) :: :ok
  def send_multiplayer_sync_request(client_pid, instance_id) do
    GenServer.cast(client_pid, {:send_multiplayer_sync_request, instance_id})
  end

  ## GenServer Implementation

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case state.state do
      :connected ->
        {:reply, :ok, state}

      _ ->
        case do_connect(state) do
          {:ok, updated_state} ->
            {:reply, :ok, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | state: :error}}
        end
    end
  end

  @impl true
  def handle_call(:disconnect, _from, state) do
    updated_state = do_disconnect(state)
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:find_session, criteria}, _from, state) do
    case ensure_connected(state) do
      {:ok, updated_state} ->
        packet = %{
          "type" => "matchmaking_find_session",
          "criteria" => criteria
        }

        case send_meta_game_packet(updated_state, packet) do
          :ok ->
            {:reply, :ok, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, updated_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:authenticate, user_id, token}, _from, state) do
    case ensure_connected(state) do
      {:ok, updated_state} ->
        packet = %{
          "type" => "auth_authenticate",
          "user_id" => user_id,
          "token" => token
        }

        case send_meta_game_packet(updated_state, packet) do
          :ok ->
            {:reply, :ok, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, updated_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:join_session, session_id}, _from, state) do
    case ensure_connected(state) do
      {:ok, updated_state} ->
        packet = %{
          "type" => "session_join",
          "session_id" => session_id
        }

        case send_meta_game_packet(updated_state, packet) do
          :ok ->
            {:reply, :ok, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, updated_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:leave_session, _from, state) do
    case ensure_connected(state) do
      {:ok, updated_state} ->
        packet = %{"type" => "session_leave"}

        case send_meta_game_packet(updated_state, packet) do
          :ok ->
            {:reply, :ok, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, updated_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:request_scene_tree_snapshot, _from, state) do
    case ensure_connected(state) do
      {:ok, updated_state} ->
        packet = %{
          "type" => "request_scene_tree_snapshot",
          "instance_id" => updated_state.instance_id
        }

        case send_meta_game_packet(updated_state, packet) do
          :ok ->
            {:reply, :ok, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, updated_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:update_node_transform, node_path, transform}, state) do
    case ensure_connected(state) do
      {:ok, updated_state} ->
        # Create transform intent
        intent_type = "transform"
        intent_data = %{node_path: node_path, transform: transform}

        # Predict locally
        intent = %{intent_type: intent_type, intent_data: intent_data}

        predicted_state =
          SpatialNodeStoreClient.Prediction.predict(intent, updated_state.predicted_state)

        # Add to intent buffer
        sequence = updated_state.sequence + 1
        timestamp = System.system_time(:millisecond)

        intent_buffer =
          SpatialNodeStoreClient.IntentBuffer.add_intent(
            updated_state.intent_buffer,
            sequence,
            intent_type,
            intent_data,
            timestamp
          )

        # Send intent to server
        packet = %{
          "type" => "player_intent",
          "intent_type" => intent_type,
          "intent_data" => intent_data,
          "sequence" => sequence,
          "timestamp" => timestamp
        }

        case send_meta_game_packet(updated_state, packet) do
          :ok ->
            {:noreply,
             %{
               updated_state
               | intent_buffer: intent_buffer,
                 sequence: sequence,
                 predicted_state: predicted_state
             }}

          {:error, _reason} ->
            {:noreply, updated_state}
        end

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:add_scene_node, node_path, node_data}, state) do
    case ensure_connected(state) do
      {:ok, updated_state} ->
        packet = %{
          "type" => "add_scene_node",
          "node_path" => node_path,
          "node_data" => node_data
        }

        send_simulation_packet(updated_state, packet)
        {:noreply, updated_state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:remove_scene_node, node_path}, state) do
    case ensure_connected(state) do
      {:ok, updated_state} ->
        packet = %{
          "type" => "remove_scene_node",
          "node_path" => node_path
        }

        send_simulation_packet(updated_state, packet)
        {:noreply, updated_state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_player_intent, intent_type, intent_data}, state) do
    case ensure_connected(state) do
      {:ok, updated_state} ->
        # Predict locally
        intent = %{intent_type: intent_type, intent_data: intent_data}

        predicted_state =
          SpatialNodeStoreClient.Prediction.predict(intent, updated_state.predicted_state)

        # Add to intent buffer
        sequence = updated_state.sequence + 1
        timestamp = System.system_time(:millisecond)

        intent_buffer =
          SpatialNodeStoreClient.IntentBuffer.add_intent(
            updated_state.intent_buffer,
            sequence,
            intent_type,
            intent_data,
            timestamp
          )

        # Send intent to server
        packet = %{
          "type" => "player_intent",
          "intent_type" => intent_type,
          "intent_data" => intent_data,
          "sequence" => sequence,
          "timestamp" => timestamp
        }

        case send_meta_game_packet(updated_state, packet) do
          :ok ->
            {:noreply,
             %{
               updated_state
               | intent_buffer: intent_buffer,
                 sequence: sequence,
                 predicted_state: predicted_state
             }}

          {:error, _reason} ->
            {:noreply, updated_state}
        end

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_multiplayer_sync_request, instance_id}, state) do
    case ensure_connected(state) do
      {:ok, updated_state} ->
        packet = %{
          "type" => "multiplayer_sync_request",
          "instance_id" => instance_id
        }

        send_meta_game_packet(updated_state, packet)
        {:noreply, updated_state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:enet, channel_id, packet_binary}, state) do
    case :erlang.binary_to_term(packet_binary, [:safe]) do
      packet when is_map(packet) ->
        updated_state = handle_server_packet(state, channel_id, packet)
        {:noreply, updated_state}

      _ ->
        Logger.warning("Received invalid packet on channel #{channel_id}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:peer_connected, _connection_ref, _peer_info, _meta_game_channel, _simulation_channel},
        state
      ) do
    # Connection established (channels already set in do_connect)
    {:noreply, state}
  end

  @impl true
  def handle_info({:peer_disconnected, _info}, state) do
    Logger.info("Peer disconnected")
    updated_state = do_disconnect(state)
    {:noreply, updated_state}
  end

  @impl true
  def terminate(_reason, state) do
    do_disconnect(state)
    :ok
  end

  ## Private Functions

  defp via_tuple(instance_id) do
    # Use a simple name registration instead of Registry
    String.to_atom("simulation_client_#{instance_id}")
  end

  defp do_connect(state) do
    client_pid = self()
    connection_ref = make_ref()

      # Create connection function for ENet
      connect_fun = fn peer_info ->
        peer_id = Map.get(peer_info, :peer_id)
        channels = Map.get(peer_info, :channels, %{})

        Logger.info("Client: connect_fun called for peer_id=#{inspect(peer_id)}")

        # Extract channels from peer_info
        meta_game_channel = Map.get(channels, @meta_game_channel)
        simulation_channel = Map.get(channels, @simulation_channel)

        # Send connection info to client GenServer
        send(
          client_pid,
          {:peer_connected, connection_ref, peer_info, meta_game_channel, simulation_channel}
        )

        # Spawn a process to handle this peer's messages
        peer_pid =
          spawn_link(fn ->
            peer_loop(peer_id, state.enet_host, channels, client_pid)
          end)

        {:ok, peer_pid}
      end

      client_options = [peer_limit: 100, channel_limit: @default_channel_count]

      # Start ENet DTLS host
      case Enet.start_dtls_host(0, connect_fun, client_options) do
        {:ok, host_port} ->
          Logger.info("ENet client host started on port #{host_port}")

          # Connect to server
          case Enet.connect_peer(
                 host_port,
                 state.server_host,
                 state.server_port,
                 @default_channel_count
               ) do
            {:ok, peer_pid} ->
              handle_peer_connection(connection_ref, peer_pid, host_port, state)

            {:error, reason} ->
              Enet.stop_host(host_port)
              {:error, {:connect_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:host_start_failed, reason}}
      end
  rescue
    e ->
      {:error, {:exception, e}}
  end

  defp handle_peer_connection(connection_ref, peer_pid, host_port, state) do
    # Wait for connection and channels from connect_fun
    case wait_for_connection_with_channels(connection_ref, @connection_timeout_ms) do
      {:ok, meta_game_channel, simulation_channel} ->
        Logger.info("Connected to server at #{state.server_host}:#{state.server_port}")

        {:ok,
         %{
           state
           | state: :connected,
             enet_host: host_port,
             peer_pid: peer_pid,
             meta_game_channel: meta_game_channel,
             simulation_channel: simulation_channel
         }}

      {:error, reason} ->
        Enet.disconnect_peer(peer_pid)
        Enet.stop_host(host_port)
        {:error, reason}
    end
  end

  defp do_disconnect(state) do
    if state.enet_host do
      if state.peer_pid do
        Enet.disconnect_peer(state.peer_pid)
      end

      Enet.stop_host(state.enet_host)
    end

    %{
      state
      | state: :disconnected,
        enet_host: nil,
        peer_pid: nil,
        meta_game_channel: nil,
        simulation_channel: nil
    }
  end

  defp wait_for_connection_with_channels(connection_ref, timeout_ms) do
    start_time = System.monotonic_time(:millisecond)

    wait_loop_with_channels(connection_ref, start_time, timeout_ms)
  end

  defp wait_loop_with_channels(connection_ref, start_time, timeout_ms) do
    if System.monotonic_time(:millisecond) - start_time > timeout_ms do
      {:error, :timeout}
    else
      receive do
        {:peer_connected, ^connection_ref, _peer_info, meta_game_channel, simulation_channel}
        when is_pid(meta_game_channel) and is_pid(simulation_channel) ->
          {:ok, meta_game_channel, simulation_channel}
      after
        50 ->
          wait_loop_with_channels(connection_ref, start_time, timeout_ms)
      end
    end
  end

  defp peer_loop(peer_id, host_port, channels, client_pid) do
    receive do
      {:enet, channel_id, packet} ->
        # Forward packet to client GenServer
        send(client_pid, {:enet, channel_id, packet})
        peer_loop(peer_id, host_port, channels, client_pid)

      {:peer_connected, _info} ->
        # Connection established (already handled)
        peer_loop(peer_id, host_port, channels, client_pid)

      {:peer_disconnected, _info} ->
        send(client_pid, {:peer_disconnected, peer_id})
        :ok

      other ->
        Logger.debug("Client peer #{inspect(peer_id)} received message: #{inspect(other)}")
        peer_loop(peer_id, host_port, channels, client_pid)
    end
  end

  defp ensure_connected(state) do
    case state.state do
      :connected ->
        {:ok, state}

      _ ->
        case do_connect(state) do
          {:ok, updated_state} ->
            {:ok, updated_state}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp send_meta_game_packet(state, packet) do
    if state.meta_game_channel do
      packet_binary = :erlang.term_to_binary(packet)
      Enet.send_reliable(state.meta_game_channel, packet_binary)
      :ok
    else
      {:error, :not_connected}
    end
  end

  defp send_simulation_packet(state, packet) do
    if state.simulation_channel do
      packet_binary = :erlang.term_to_binary(packet)
      Enet.send_unreliable(state.simulation_channel, packet_binary)
      :ok
    else
      {:error, :not_connected}
    end
  end

  defp handle_server_packet(state, _channel_id, packet) do
    packet_type = Map.get(packet, "type")

    case packet_type do
      "player_state_update" ->
        # Authoritative state from server - check for rollback
        handle_player_state_update(state, packet)

      "scene_tree_snapshot" ->
        # Scene tree snapshot response
        node_count = Map.get(packet, "node_count", 0)
        Logger.debug("Received scene tree snapshot: #{node_count} nodes")

        # Forward to callback if set (e.g., observer client)
        if state.callback_pid do
          send(state.callback_pid, {:scene_tree_snapshot_received, packet})
        end

        state

      "matchmaking_session_found" ->
        Logger.info("Session found: #{Map.get(packet, "session_id", "unknown")}")
        state

      "auth_success" ->
        Logger.info("Authentication successful")
        state

      "session_joined" ->
        Logger.info("Joined session: #{Map.get(packet, "session_id", "unknown")}")
        state

      "session_left" ->
        Logger.info("Left session")
        state

      _ ->
        Logger.debug("Received packet: #{packet_type}")
        state
    end
  end

  defp handle_player_state_update(state, packet) do
    server_sequence = Map.get(packet, "sequence", 0)
    authoritative_state = Map.get(packet, "state", %{})

    # Check if rollback is needed
    case SpatialNodeStoreClient.Prediction.reconcile(
           state.predicted_state,
           authoritative_state,
           0.01
         ) do
      {:ok, _} ->
        # States match, no rollback needed
        %{state | predicted_state: authoritative_state}

      {:correction, _} ->
        # Rollback needed - re-simulate from server sequence
        Logger.debug("Rollback needed: server sequence #{server_sequence}")

        # Get intents since rollback point
        intents =
          SpatialNodeStoreClient.IntentBuffer.get_intents_since(
            state.intent_buffer,
            server_sequence
          )

        # Re-simulate each intent
        corrected_state =
          Enum.reduce(intents, authoritative_state, fn intent, acc_state ->
            intent_map = %{
              intent_type: intent.intent_type,
              intent_data: intent.intent_data
            }

            SpatialNodeStoreClient.Prediction.apply_intent(intent_map, acc_state)
          end)

        %{state | predicted_state: corrected_state}
    end
  end
end
