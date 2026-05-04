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
    GenServer.call(via(guild_id), :get_status)
  end

  def init(args) do
    guild_id = Keyword.fetch!(args, :guild_id)

    state = default_state(guild_id)

    schedule_tick()
    schedule_persist()
    {:ok, state, {:continue, :load_state}}
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

  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  # Missions
  def handle_call({:start_mission, args}, _from, state) do
    case Hangar.get_available_ships(state.guild_id) do
      [ship | _] ->
        case Hangar.set_ship_on_mission(state.guild_id, ship.id) do
          :ok ->
            mission_args =
              Map.merge(args, %{
                ship_id: ship.id,
                ship_stats: ship.stats,
                ship_hull: ship.current_hull,
                station_pid: self()
              })

            case DynamicSupervisor.start_child(
                   get_mission_sup(state.guild_id),
                   {Bulkhead.Mission.Server, mission_args}
                 ) do
              {:ok, pid} ->
                new_state = %{
                  state
                  | active_missions: MapSet.put(state.active_missions, pid),
                    dirty: true
                }

                {:reply, {:ok, pid}, new_state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      [] ->
        {:reply, {:error, :no_ships_available}, state}
    end
  end

  def handle_info(
        {:mission_complete, rewards, %{ship_id: ship_id, final_hull: _hull}, _pid},
        state
      ) do
    new_resources =
      Enum.reduce(rewards, state.resources, fn {resource, amount}, acc ->
        Map.update(acc, resource, amount, &(&1 + amount))
      end)

    Hangar.start_recovery(state.guild_id, ship_id)

    Phoenix.PubSub.broadcast(Bulkhead.PubSub, "galaxy:events", {
      :mission_complete,
      %{guild_id: state.guild_id, rewards: rewards}
    })

    {:noreply, %{state | resources: new_resources, dirty: true}}
  end

  def handle_info({:mission_failed, _reason, %{ship_id: ship_id}, _pid}, state) do
    Hangar.start_recovery(state.guild_id, ship_id)
    Hangar.update_ship_hull(state.guild_id, ship_id, 20)
    {:noreply, state}
  end

  # Persistence

  def handle_info(:persist, %{dirty: false} = state) do
    schedule_persist()
    {:noreply, state}
  end

  def handle_info(:persist, %{dirty: true} = state) do
    snapshot = {state.guild_id, state.resources, state.metadata}
    parent = self()

    Task.start(fn ->
      result = Bulkhead.Station.Store.save(snapshot)
      send(parent, {:persist_done, result})
    end)

    schedule_persist()
    # dirty остаётся true пока не придёт :persist_done
    {:noreply, state}
  end

  def handle_info({:persist_done, {:ok, _record}}, state) do
    {:noreply, %{state | dirty: false}}
  end

  def handle_info({:persist_done, {:error, changeset}}, state) do
    require Logger
    Logger.error("Failed to persist station: #{inspect(changeset.errors)}")

    {:noreply, state}
  end

  # def handle_info(:persist, state) do
  #   if state.dirty do
  #     string_resources =
  #       Map.new(state.resources, fn {k, v} -> {to_string(k), v} end)

  #     Bulkhead.Station.Store.save(state.guild_id, string_resources, state.metadata)
  #   end

  #   schedule_persist()
  #   {:noreply, %{state | dirty: false}}
  # end

  # Helpers
  defp get_mission_sup(guild_id),
    do: {:via, Registry, {Bulkhead.Registry, {:mission_sup, guild_id}}}

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
