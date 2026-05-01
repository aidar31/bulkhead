defmodule Bulkhead.Hangar do
  use GenServer
  require Logger

  alias Bulkhead.Station.Store

  # Public API
  def start_link(args) do
    guild_id = Keyword.fetch!(args, :guild_id)
    GenServer.start_link(__MODULE__, args, name: via(guild_id))
  end

  def get_info(guild_id) do
    GenServer.call(via(guild_id), :get_info)
  end

  def get_available_ships(guild_id) do
    GenServer.call(via(guild_id), :get_available_ships)
  end

  def set_ship_on_mission(guild_id, ship_id) do
    GenServer.call(via(guild_id), {:set_on_mission, ship_id})
  end

  def start_recovery(guild_id, ship_id) do
    GenServer.cast(via(guild_id), {:start_recovery, ship_id})
  end

  # Callbacks

  def init(args) do
    guild_id = Keyword.fetch!(args, :guild_id)

    building = Store.get_building(guild_id, "hangar") || %{level: 1}
    ships = Store.get_all_ships(guild_id) |> index_by_id()

    state = %{
      guild_id: guild_id,
      level: building.level,
      ships: ships,
      dirty: false
    }

    Enum.each(ships, fn {id, ship} ->
      if ship.status == "recovering" do
        schedule_recovery_check(id, ship.available_at)
      end
    end)

    schedule_persist()

    {:ok, state}
  end

  def handle_call(:get_info, _from, state) do
    {:reply, %{level: state.level, ships: Map.values(state.ships)}, state}
  end

  def handle_call(:get_available_ships, _from, state) do
    available = Enum.filter(Map.values(state.ships), &(&1.status == "idle"))
    {:reply, available, state}
  end

  def handle_call({:set_on_mission, ship_id}, _from, state) do
    case Map.get(state.ships, ship_id) do
      %{status: "idle"} = ship ->
        new_ship = %{ship | status: "on_mission"}

        Store.set_ship_on_mission(ship_id)

        new_ships = Map.put(state.ships, ship_id, new_ship)
        {:reply, :ok, %{state | ships: new_ships}}

      _ ->
        {:reply, {:error, :ship_not_available}, state}
    end
  end

  def handle_cast({:start_recovery, ship_id}, state) do
    # Расчет времени: 5 минут (300с) база / уровень ангара
    duration_sec = trunc(300 / state.level)
    available_at = DateTime.add(DateTime.utc_now(), duration_sec, :second)

    # Обновляем БД (чтобы после краша мы знали, когда корабль выйдет)
    Store.set_ship_recovering(ship_id, available_at)

    new_ships =
      Map.update!(state.ships, ship_id, fn s ->
        %{s | status: "recovering", available_at: available_at}
      end)

    schedule_recovery_check(ship_id, available_at)

    {:noreply, %{state | ships: new_ships}}
  end

  def handle_info({:recovery_complete, ship_id}, state) do
    case Map.get(state.ships, ship_id) do
      %{status: "recovering"} = ship ->
        max_hull = ship.stats["hull_max"] || 100

        Store.set_ship_idle(ship_id)
        Store.update_ship_hull(ship_id, max_hull)

        new_ship = %{ship | status: "idle", available_at: nil, current_hull: max_hull}

        broadcast_ready(state.guild_id, ship)

        {:noreply, %{state | ships: Map.put(state.ships, ship_id, new_ship)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:persist, state) do
    # Тут можно сохранять уровень ангара, если он поменялся
    # Store.save_building(state.guild_id, "hangar", state.level)
    schedule_persist()
    {:noreply, %{state | dirty: false}}
  end

  # Helpers

  defp schedule_recovery_check(ship_id, available_at) do
    delay = DateTime.diff(available_at, DateTime.utc_now(), :millisecond)
    Process.send_after(self(), {:recovery_complete, ship_id}, max(0, delay))
  end

  defp index_by_id(ships), do: Map.new(ships, &{&1.id, &1})

  defp via(guild_id), do: {:via, Registry, {Bulkhead.Registry, {:hangar, guild_id}}}

  defp schedule_persist(), do: Process.send_after(self(), :persist, 60_000)

  defp broadcast_ready(guild_id, ship) do
    Phoenix.PubSub.broadcast(Bulkhead.PubSub, "station:#{guild_id}", {
      :ship_ready,
      %{ship_id: ship.id, ship_name: ship.name}
    })
  end
end
