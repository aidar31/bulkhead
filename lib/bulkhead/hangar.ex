defmodule Bulkhead.Hangar do
  use GenServer

  # Public API
  def start_link(args) do
    guild_id = Keyword.fetch!(args, :guild_id)
    GenServer.start_link(__MODULE__, args, name: via(guild_id))
  end

  def get_available_ships(guild_id) do
    GenServer.call(via(guild_id), :get_available_ships)
  end

  def start_recovery(guild_id, ship_id, duration_sec) do
    GenServer.cast(via(guild_id), {:start_recovery, ship_id, duration_sec})
  end

  def set_ship_on_mission(guild_id, ship_id) do
    GenServer.cast(via(guild_id), {:set_on_mission, ship_id})
  end

  def get_ships(guild_id) do
    GenServer.call(via(guild_id), :get_ships)
  end

  def reload(guild_id) do
    GenServer.cast(via(guild_id), :reload_from_db)
  end

  def init(args) do
    guild_id = args[:guild_id]

    ships = load_ships(guild_id)

    ships
    |> Enum.filter(&(&1.status == "recovering"))
    |> Enum.each(fn ship ->
      remaining = DateTime.diff(ship.available_at, DateTime.utc_now(), :millisecond)

      if remaining > 0 do
        Process.send_after(self(), {:recovery_complete, ship.id}, remaining)
      else
        # Уже должен был восстановиться пока мы были offline
        send(self(), {:recovery_complete, ship.id})
      end
    end)

    {:ok, %{guild_id: guild_id, ships: index_by_id(ships)}}
  end

  def handle_cast(:reload_from_db, state) do
    new_ships = load_ships(state.guild_id)
    {:noreply, %{state | ships: index_by_id(new_ships)}}
  end

  def handle_call(:get_ships, _from, state) do
    {:reply, Map.values(state.ships), state}
  end

  def handle_call(:get_available_ships, _from, state) do
    available =
      state.ships
      |> Map.values()
      |> Enum.filter(&(&1.status == "idle"))

    {:reply, available, state}
  end

  def handle_cast({:start_recovery, ship_id, duration_sec}, state) do
    available_at = DateTime.add(DateTime.utc_now(), duration_sec, :second)

    # Обновляем в БД
    Bulkhead.Station.Store.set_ship_recovering(ship_id, available_at)

    # Обновляем в памяти
    new_ships =
      Map.update!(state.ships, ship_id, fn ship ->
        %{ship | status: "recovering", available_at: available_at}
      end)

    # Сами себе шлём сообщение через N секунд
    Process.send_after(self(), {:recovery_complete, ship_id}, duration_sec * 1000)

    {:noreply, %{state | ships: new_ships}}
  end

  def handle_info({:recovery_complete, ship_id}, state) do
    ship = state.ships[ship_id]
    max_hull = ship.stats["hull_max"] || 100

    # 2. Обновляем БД: ставим статус idle и восстанавливаем HP
    Bulkhead.Station.Store.set_ship_idle(ship_id)
    Bulkhead.Station.Store.update_ship_hull(ship_id, max_hull)

    # 3. Обновляем память (state)
    new_ships =
      Map.update!(state.ships, ship_id, fn s ->
        %{s | status: "idle", available_at: nil, current_hull: max_hull}
      end)

    # 4. Уведомление в Discord
    Phoenix.PubSub.broadcast(Bulkhead.PubSub, "station:#{state.guild_id}", {
      :ship_ready,
      %{ship_id: ship_id, ship_name: ship.name}
    })

    {:noreply, %{state | ships: new_ships}}
  end

  def handle_cast({:set_on_mission, ship_id}, state) do
    new_ships =
      Map.update!(state.ships, ship_id, fn ship ->
        %{ship | status: "on_mission"}
      end)

    # В БД мы уже обновили в Station, здесь только память
    {:noreply, %{state | ships: new_ships}}
  end

  defp load_ships(guild_id) do
    Bulkhead.Station.Store.get_all_ships(guild_id)
  end

  defp index_by_id(ships) do
    Map.new(ships, &{&1.id, &1})
  end

  defp via(guild_id),
    do: {:via, Registry, {Bulkhead.Registry, {:hangar, guild_id}}}
end
