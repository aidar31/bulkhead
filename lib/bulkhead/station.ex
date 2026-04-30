defmodule Bulkhead.Station do
  use GenServer, restart: :transient
  require Logger

  alias Bulkhead.Hangar

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

  def get_status(guild_id) do
    case Bulkhead.Station.Cache.get(guild_id) do
      {:ok, state} -> {:ok, state}
      {:error, :not_found} -> {:ok, GenServer.call(via(guild_id), :get_status)}
    end
  end

  def init(args) do
    guild_id = Keyword.fetch!(args, :guild_id)

    state = default_state(guild_id)

    {:ok, mission_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    {:ok, hangar_pid} = Bulkhead.Hangar.start_link(guild_id: guild_id)

    schedule_tick()
    schedule_persist()
    {:ok, Map.put(state, :mission_sup, mission_sup), {:continue, :load_state}}
  end

  def handle_continue(:load_state, state) do
    record = Bulkhead.Station.Store.load_or_create(state.guild_id)

    resources = %{
      credits: record.resources["credits"] || 100,
      scrap: record.resources["scrap"] || 50,
      energy: record.resources["energy"] || 100,
      mining_level: record.resources["mining_level"] || 1
    }

    new_state = %{
      state
      | resources: resources,
        metadata: record.metadata,
        loaded: true
    }

    {:noreply, new_state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  def handle_info(:tick, state) do
    earned = state.resources.mining_level * 2
    new_resources = %{state.resources | credits: state.resources.credits + earned}
    new_state = %{state | resources: new_resources, dirty: true}

    Phoenix.PubSub.broadcast(
      Bulkhead.PubSub,
      "station:#{state.guild_id}",
      {:tick,
       %{earned: earned, credits: new_state.resources.credits, scrap: new_state.resources.scrap}}
    )

    Logger.info(
      "Station #{state.guild_id} tick: earned #{earned} credits, total credits: #{new_state.resources.credits}"
    )

    schedule_tick()
    {:noreply, new_state}
  end

  # Missions

  # def handle_call({:start_mission, mission_args}, _from, state) do
  #   mission_id = :crypto.strong_rand_bytes(8) |> Base.encode16()
  #   mission_args = Map.put(mission_args, :mission_id, mission_id)

  #   case DynamicSupervisor.start_child(state.mission_sup, {Bulkhead.Mission.Server, mission_args}) do
  #     {:ok, pid} ->
  #       new_state = %{
  #         state
  #         | active_missions: MapSet.put(state.active_missions, pid),
  #           dirty: true
  #       }

  #       {:reply, {:ok, mission_id}, new_state}

  #     {:error, reason} ->
  #       Logger.error("Failed to start mission for station #{state.guild_id}: #{inspect(reason)}")
  #       {:reply, {:error, reason}, state}
  #   end
  # end
  def handle_call({:start_mission, %{type: :expedition} = args}, _from, state) do
    # Прямое обращение к процессу Ангара в памяти
    case Hangar.get_available_ships(state.guild_id) do
      [ship | _] ->
        with {:ok, building} <- get_hangar_info(state.guild_id) do
          mission_args =
            Map.merge(args, %{
              ship_id: ship.id,
              ship_stats: ship.stats,
              ship_hull: ship.current_hull,
              hangar_level: building.level,
              station_pid: self()
            })

          case DynamicSupervisor.start_child(
                 state.mission_sup,
                 {Bulkhead.Mission.Server, mission_args}
               ) do
            {:ok, pid} ->
              Bulkhead.Station.Store.set_ship_on_mission(ship.id)
              Hangar.set_ship_on_mission(state.guild_id, ship.id)

              new_state = %{
                state
                | active_missions: MapSet.put(state.active_missions, pid),
                  dirty: true
              }

              {:reply, {:ok, pid}, new_state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      [] ->
        {:reply, {:error, :no_ships_available}, state}
    end
  end

  def handle_info(
        {:mission_complete, rewards, %{ship_id: ship_id, final_hull: hull}, _pid},
        state
      ) do
    new_resources =
      state.resources
      |> Map.update("scrap", 0, &(&1 + Map.get(rewards, :scrap, 0)))

    Bulkhead.Station.Store.update_ship_hull(ship_id, hull)

    with {:ok, building} <- get_hangar_info(state.guild_id) do
      recovery_sec = trunc(300 / building.level)
      Hangar.start_recovery(state.guild_id, ship_id, recovery_sec)
    end

    Phoenix.PubSub.broadcast(Bulkhead.PubSub, "galaxy:events", {
      :mission_complete,
      %{guild_id: state.guild_id, rewards: rewards}
    })

    {:noreply, %{state | resources: new_resources, dirty: true}}
  end

  defp get_hangar_info(guild_id) do
    case Bulkhead.Station.Store.get_building(guild_id, "hangar") do
      nil -> {:error, :no_hangar}
      b -> {:ok, b}
    end
  end

  def handle_info({:mission_failed, _reason, %{ship_id: ship_id}, _pid}, state) do
    with {:ok, building} <- get_hangar_info(state.guild_id) do
      # Формула: 5 минут (300с) база, делится на уровень ангара
      recovery_sec = trunc(300 / building.level * 2)
      Hangar.start_recovery(state.guild_id, ship_id, recovery_sec)
    end

    Bulkhead.Station.Store.update_ship_hull(ship_id, 20)

    {:noreply, state}
  end

  # Persistence

  def handle_info(:persist, %{dirty: false} = state) do
    schedule_persist()
    {:noreply, state}
  end

  def handle_info(:persist, state) do
    if state.dirty do
      Bulkhead.Station.Store.save(state.guild_id, state.resources, state.metadata)
    end

    Logger.debug("Persisting station #{state.guild_id} state: #{inspect(state)}")
    schedule_persist()
    {:noreply, %{state | dirty: false}}
  end

  defp default_state(guild_id) do
    %{
      guild_id: guild_id,
      resources: %{},
      metadata: %{},
      active_missions: MapSet.new(),
      active_event: nil,
      loaded: false,
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
