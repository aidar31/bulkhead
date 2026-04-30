defmodule Bulkhead.Station do
  use GenServer, restart: :transient
  require Logger

  def start_link(args) do
    guild_id = Keyword.fetch!(args, :guild_id)
    GenServer.start_link(__MODULE__, args, name: via(guild_id))
  end

  def start_mission(guild_id, mission_args) do
    case ensure_started(guild_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:start_mission, mission_args})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def init(args) do
    guild_id = Keyword.fetch!(args, :guild_id)

    state = default_state(guild_id)

    {:ok, mission_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    schedule_tick()
    schedule_persist()
    {:ok, Map.put(state, :mission_sup, mission_sup)}
  end

  def handle_info(:tick, state) do
    earned = state.mining_level * 2
    new_state = %{state | credits: state.credits + earned, dirty: true}

    Phoenix.PubSub.broadcast(
      Bulkhead.PubSub,
      "station:#{state.guild_id}",
      {:tick, %{earned: earned, credits: new_state.credits, scrap: new_state.scrap}}
    )

    Logger.info(
      "Station #{state.guild_id} tick: earned #{earned} credits, total credits: #{new_state.credits}"
    )

    schedule_tick()
    {:noreply, new_state}
  end

  # Missions

  def handle_call({:start_mission, mission_args}, _from, state) do
    mission_id = :crypto.strong_rand_bytes(8) |> Base.encode16()
    mission_args = Map.put(mission_args, :mission_id, mission_id)

    case DynamicSupervisor.start_child(state.mission_sup, {Bulkhead.Mission.Server, mission_args}) do
      {:ok, pid} ->
        new_state = %{
          state
          | active_missions: MapSet.put(state.active_missions, pid),
            dirty: true
        }

        {:reply, {:ok, mission_id}, new_state}

      {:error, reason} ->
        Logger.error("Failed to start mission for station #{state.guild_id}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_info({:mission_complete, rewards, _pid}, state) do
    new_credits = state.credits + Map.get(rewards, :credits, 0)
    new_scrap = state.scrap + Map.get(rewards, :scrap, 0)

    {:noreply, %{state | credits: new_credits, scrap: new_scrap, dirty: true}}
  end

  def handle_info({:mission_failed, reason, _pid}, state) do
    Logger.info("Mission failed for station #{state.guild_id}: #{reason}")
    {:noreply, state}
  end

  # Persistence

  def handle_info(:persist, %{dirty: false} = state) do
    schedule_persist()
    {:noreply, state}
  end

  def handle_info(:persist, state) do
    # Save to DB if dirty
    # TODO: implement actual persistence
    # Cache.put({:station, state.guild_id}, state)
    Logger.debug("Persisting station #{state.guild_id} state: #{inspect(state)}")
    schedule_persist()
    {:noreply, %{state | dirty: false}}
  end

  defp default_state(guild_id) do
    %{
      guild_id: guild_id,
      credits: 100,
      scrap: 50,
      energy: 100,
      mining_level: 1,
      active_missions: MapSet.new(),
      active_event: nil,
      dirty: false
    }
  end

  def whereis(guild_id), do: GenServer.whereis(via(guild_id))

  def ensure_started(guild_id) do
    case whereis(guild_id) do
      nil -> Bulkhead.Station.Supervisor.start_station(guild_id)
      pid -> {:ok, pid}
    end
  end

  defp via(guild_id), do: {:via, Registry, {Bulkhead.Registry, {:station, guild_id}}}
  defp schedule_tick(), do: Process.send_after(self(), :tick, 10_000)
  defp schedule_persist(), do: Process.send_after(self(), :persist, 60_000)
end
