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

  def get_player_ships(guild_id, user_id) do
    GenServer.call(via(guild_id), {:get_player_ships, user_id})
  end

  def set_ship_on_mission(guild_id, ship_id) do
    GenServer.call(via(guild_id), {:set_on_mission, ship_id})
  end

  def start_recovery(guild_id, ship_id) do
    GenServer.cast(via(guild_id), {:start_recovery, ship_id})
  end

  def install_module(guild_id, ship_id, module_id, user_id) do
    GenServer.call(via(guild_id), {:install_module, ship_id, module_id, user_id})
  end

  def uninstall_module(guild_id, ship_id, module_id, user_id) do
    GenServer.call(via(guild_id), {:uninstall_module, ship_id, module_id, user_id})
  end

  def update_ship_hull(guild_id, ship_id, new_hull) do
    GenServer.cast(via(guild_id), {:update_hull, ship_id, new_hull})
  end

  # Callbacks

  def init(args) do
    guild_id = Keyword.fetch!(args, :guild_id)

    state = %{
      guild_id: guild_id,
      level: 1,
      ships: %{},
      dirty: false,
      loaded: false
    }

    {:ok, state, {:continue, :load_data}}
  end

  def handle_continue(:load_data, state) do
    building = Store.get_building(state.guild_id, "hangar") || %{level: 1}

    ships =
      Store.get_all_ships(state.guild_id)
      |> Enum.map(fn ship ->
        case ship.status do
          "on_mission" -> %{ship | status: "idle"}
          _ -> ship
        end
      end)
      |> index_by_id()

    Enum.each(ships, fn {id, ship} ->
      if ship.status == "recovering" do
        schedule_recovery_check(id, ship.available_at)
      end
    end)

    schedule_persist()

    new_state = %{state | level: building.level, ships: ships, loaded: true}

    {:noreply, new_state}
  end

  def handle_cast({:update_hull, ship_id, new_hull}, state) do
    Store.update_ship_hull(ship_id, new_hull)

    new_ships =
      Map.update!(state.ships, ship_id, fn ship ->
        %{ship | current_hull: new_hull}
      end)

    {:noreply, %{state | ships: new_ships}}
  end

  def handle_call(:get_info, _from, %{loaded: false} = state) do
    {:reply, :loading, state}
  end

  def handle_call(:get_info, _from, state) do
    {:reply, %{level: state.level, ships: Map.values(state.ships)}, state}
  end

  def handle_call(:get_available_ships, _from, state) do
    available = Enum.filter(Map.values(state.ships), &(&1.status == "idle"))
    {:reply, available, state}
  end

  def handle_call({:get_player_ships, user_id}, _from, state) do
    player_ships =
      state.ships
      |> Map.values()
      |> Enum.filter(&(&1.user_id == user_id))

    {:reply, player_ships, state}
  end

  def handle_call({:set_on_mission, ship_id}, _from, state) do
    case Map.get(state.ships, ship_id) do
      %{status: "idle"} = ship ->
        new_ship = %{ship | status: "on_mission"}

        new_ships = Map.put(state.ships, ship_id, new_ship)
        {:reply, :ok, %{state | ships: new_ships}}

      _ ->
        {:reply, {:error, :ship_not_available}, state}
    end
  end

  def handle_call({:install_module, ship_id, module_id, user_id}, _from, state) do
    ship = Map.get(state.ships, ship_id)

    with :ok <- check_ship_owner(ship, user_id),
         :ok <- check_ship_idle(ship),
         :ok <- check_slots_available(ship),
         {:ok, mod_def} <- get_module_def(module_id),
         :ok <- check_category_unique(ship, mod_def.category, state) do
      slot_index = next_free_slot(ship)

      {:ok, _} = Bulkhead.Station.Store.install_module(ship_id, module_id, slot_index)
      new_ship = reload_ship_with_modules(ship_id)

      Bulkhead.Repo.get!(Bulkhead.Game.Ship, ship_id)
      |> Bulkhead.Game.Ship.changeset(%{stats: new_ship.stats})
      |> Bulkhead.Repo.update!()

      new_ships = Map.put(state.ships, ship_id, new_ship)

      {:reply, {:ok, new_ship}, %{state | ships: new_ships}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
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

  def handle_cast({:release_ship, ship_id}, state) do
    new_ships =
      Map.update!(state.ships, ship_id, fn ship ->
        %{ship | status: "idle"}
      end)

    {:noreply, %{state | ships: new_ships}}
  end

  def handle_info({:recovery_complete, ship_id}, state) do
    case Map.get(state.ships, ship_id) do
      %{status: "recovering"} = ship ->
        new_ship = reload_ship_with_modules(ship_id)
        max_hull = Map.get(new_ship.stats, "hull_max", 100)

        Store.set_ship_idle(ship_id)
        Store.update_ship_hull(ship_id, max_hull)

        new_ship = %{new_ship | status: "idle", available_at: nil, current_hull: max_hull}

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

  # Guards
  defp check_ship_owner(%{user_id: uid}, user_id) when uid == user_id, do: :ok
  defp check_ship_owner(_, _), do: {:error, :not_your_ship}

  defp check_ship_idle(%{status: "idle"}), do: :ok
  defp check_ship_idle(_), do: {:error, :ship_not_idle}

  defp check_slots_available(%{slots_total: total, id: ship_id}) do
    used = Bulkhead.Station.Store.count_modules(ship_id)
    if used < total, do: :ok, else: {:error, :no_slots_available}
  end

  defp check_category_unique(ship, category, state) do
    installed = Bulkhead.Station.Store.get_ship_modules(ship.id)
    already_has = Enum.any?(installed, &(&1.category == category))
    if already_has, do: {:error, :category_already_installed}, else: :ok
  end

  defp next_free_slot(ship) do
    used_slots =
      Bulkhead.Station.Store.get_ship_modules(ship.id)
      |> Enum.map(& &1.slot_index)
      |> MapSet.new()

    Enum.find(0..(ship.slots_total - 1), &(not MapSet.member?(used_slots, &1)))
  end

  # Helpers

  defp get_module_def(module_id) do
    case Bulkhead.Repo.get(Bulkhead.Game.ShipModuleDefinition, module_id) do
      nil -> {:error, :module_not_found}
      mod -> {:ok, mod}
    end
  end

  defp reload_ship_with_modules(ship_id) do
    ship = Bulkhead.Repo.get!(Bulkhead.Game.Ship, ship_id)

    installed_modules = Bulkhead.Station.Store.get_ship_modules(ship_id)

    effective_stats = Bulkhead.Game.ModuleEngine.apply_modules(ship.stats, installed_modules)

    %{ship | stats: effective_stats}
  end

  # defp get_effective_stats(ship) do
  #   base_stats = ship.stats
  #   modules = ship.metadata["equipped_modules"] || []

  #   # Пример того, как модули меняют статы
  #   Enum.reduce(modules, base_stats, fn module_id, acc ->
  #     case module_id do
  #       "heavy_plating" ->
  #         Map.update(acc, "hull_max", 0, &(&1 + 20))

  #       "overclocked_core" ->
  #         Map.update(acc, "firepower", 0, &(&1 + 5))

  #       "nanobots" ->
  #         Map.put(acc, "regen_bonus", 0.02)

  #       _ ->
  #         acc
  #     end
  #   end)
  # end

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
