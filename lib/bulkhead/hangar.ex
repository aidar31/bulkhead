defmodule Bulkhead.Hangar do
  use GenServer
  require Logger

  alias Bulkhead.Station.Store

  # --- Public API ---

  def start_link(args) do
    guild_id = Keyword.fetch!(args, :guild_id)
    GenServer.start_link(__MODULE__, args, name: via(guild_id))
  end

  def get_info(guild_id), do: GenServer.call(via(guild_id), :get_info)
  def get_available_ships(guild_id), do: GenServer.call(via(guild_id), :get_available_ships)

  def get_player_ships(guild_id, user_id),
    do: GenServer.call(via(guild_id), {:get_player_ships, user_id})

  def set_ship_on_mission(guild_id, ship_id),
    do: GenServer.call(via(guild_id), {:set_on_mission, ship_id})

  def install_module(guild_id, ship_id, mod_id, uid),
    do: GenServer.call(via(guild_id), {:install_module, ship_id, mod_id, uid})

  def uninstall_module(guild_id, ship_id, mod_id, uid),
    do: GenServer.call(via(guild_id), {:uninstall_module, ship_id, mod_id, uid})

  def start_recovery(guild_id, ship_id),
    do: GenServer.cast(via(guild_id), {:start_recovery, ship_id})

  def update_ship_hull(guild_id, ship_id, new_hull),
    do: GenServer.cast(via(guild_id), {:update_hull, ship_id, new_hull})

  def ensure_starter_ship(guild_id, user_id),
    do: GenServer.call(via(guild_id), {:ensure_starter_ship, user_id})

  def add_ship(guild_id, ship), do: GenServer.cast(via(guild_id), {:add_ship, ship})

  # --- Callbacks ---

  def init(args) do
    guild_id = Keyword.fetch!(args, :guild_id)

    state = %{
      guild_id: guild_id,
      level: 1,
      ships: %{},
      # hull_dirty: корабли с изменённым хуллом, которые надо сохранить при persist
      hull_dirty: MapSet.new(),
      # dirty: уровень ангара изменился и надо сохранить
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
        # Корабли в мисии при краше возвращаем в idle (миссия могла не завершиться)
        case ship.status do
          "on_mission" -> %{ship | status: "idle"}
          _ -> ship
        end
      end)
      |> index_by_id()

    Enum.each(ships, fn {id, ship} ->
      if ship.status == "recovering", do: schedule_recovery_check(id, ship.available_at)
    end)

    schedule_persist()

    {:noreply, %{state | level: building.level, ships: ships, loaded: true}}
  end

  # --- Calls ---

  def handle_call(:get_info, _from, %{loaded: false} = state),
    do: {:reply, :loading, state}

  def handle_call(:get_info, _from, state),
    do: {:reply, %{level: state.level, ships: Map.values(state.ships)}, state}

  def handle_call(:get_available_ships, _from, state) do
    available = state.ships |> Map.values() |> Enum.filter(&(&1.status == "idle"))
    {:reply, available, state}
  end

  # def handle_call({:get_player_ships, user_id}, _from, state) do
  #   ships = state.ships |> Map.values() |> Enum.filter(&(&1.user_id == user_id))
  #   {:reply, ships, state}
  # end

  def handle_call({:get_player_ships, user_id}, _from, state) do
    # 1. Ищем корабли в текущем стейте (в памяти)
    ships = state.ships |> Map.values() |> Enum.filter(&(&1.user_id == user_id))

    if ships == [] do
      # 2. Если пусто — создаем стартовый корабль через Store
      # ВАЖНО: это происходит внутри процесса Ангара, так что консистентность соблюдена
      case Store.create_starter_ship(state.guild_id, user_id) do
        {:ok, new_ship} ->
          # Обогащаем статы (применяем пустые модули, чтобы структура была полной)
          full_ship = %{
            new_ship
            | stats: Bulkhead.Game.ModuleEngine.apply_modules(new_ship.stats, [])
          }

          # Обновляем стейт, чтобы при следующем вызове не лезть в БД
          new_state_ships = Map.put(state.ships, full_ship.id, full_ship)

          # Помечаем dirty: true, чтобы сработал автоматический persist (если нужно)
          # Хотя Store.create_starter_ship уже сделал insert в базу.
          {:reply, [full_ship], %{state | ships: new_state_ships, dirty: true}}

        {:error, _reason} ->
          # Если база упала или еще что — возвращаем пустой список
          {:reply, [], state}
      end
    else
      # 3. Если корабли уже были в памяти — просто отдаем их
      {:reply, ships, state}
    end
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

  # install_module: всё валидируем по данным в state, только 1 запрос к БД
  def handle_call({:install_module, ship_id, module_id, user_id}, _from, state) do
    ship = Map.get(state.ships, ship_id)

    with true <-
           Bulkhead.RoleServer.can?(state.guild_id, user_id, :can_manage_modules) ||
             {:error, :no_engineer_role},
         :ok <- check_ship_owner(ship, user_id),
         :ok <- check_ship_idle(ship),
         # считаем по installed_modules в state
         :ok <- check_slots_available(ship),
         {:ok, mod_def} <- get_module_def(module_id),
         # по state
         :ok <- check_category_unique(ship, mod_def.category) do
      slot_index = next_free_slot(ship)

      # Единственный DB-запрос — сохранить инсталляцию
      # {:ok, _} = Store.install_module(ship_id, module_id, slot_index)

      # Обновляем ship в памяти, применяем эффекты модулей
      new_ship = apply_new_module(ship, mod_def, slot_index)

      # Персистим обновлённые stats в кораблей (без вызова Repo напрямую)
      # Store.update_ship_stats(ship_id, new_ship.stats)

      new_ships = Map.put(state.ships, ship_id, new_ship)
      {:reply, {:ok, new_ship}, %{state | ships: new_ships, dirty: true}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # uninstall_module: был объявлен в API, но handle_call отсутствовал → timeout
  def handle_call({:uninstall_module, ship_id, module_id, user_id}, _from, state) do
    ship = Map.get(state.ships, ship_id)

    with :ok <- check_ship_owner(ship, user_id),
         :ok <- check_ship_idle(ship),
         :ok <- check_module_installed(ship, module_id) do
      # :ok = Store.uninstall_module(ship_id, module_id)

      new_ship = remove_module_and_recalc(ship, module_id)
      Store.update_ship_stats(ship_id, new_ship.stats)

      new_ships = Map.put(state.ships, ship_id, new_ship)
      {:reply, {:ok, new_ship}, %{state | ships: new_ships}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ensure_starter_ship, user_id}, _from, state) do
    user_ships = state.ships |> Map.values() |> Enum.filter(&(&1.user_id == user_id))

    if Enum.empty?(user_ships) do
      case Store.create_starter_ship(state.guild_id, user_id) do
        {:ok, new_ship} ->
          new_ships = Map.put(state.ships, new_ship.id, new_ship)
          {:reply, [new_ship], %{state | ships: new_ships, dirty: true}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, user_ships, state}
    end
  end

  # --- Casts ---
  def handle_cast({:add_ship, ship}, state) do
    new_ships = Map.put(state.ships, ship.id, ship)
    {:noreply, %{state | ships: new_ships, dirty: true}}
  end

  # update_hull: только помечаем dirty в state, flush при persist — не бьём БД на каждый урон
  def handle_cast({:update_hull, ship_id, new_hull}, state) do
    new_ships = Map.update!(state.ships, ship_id, &%{&1 | current_hull: new_hull})
    hull_dirty = MapSet.put(state.hull_dirty, ship_id)
    {:noreply, %{state | ships: new_ships, hull_dirty: hull_dirty}}
  end

  def handle_cast({:start_recovery, ship_id}, state) do
    duration_sec = trunc(300 / state.level)
    available_at = DateTime.add(DateTime.utc_now(), duration_sec, :second)

    Store.set_ship_recovering(ship_id, available_at)

    new_ships =
      Map.update!(state.ships, ship_id, &%{&1 | status: "recovering", available_at: available_at})

    schedule_recovery_check(ship_id, available_at)
    {:noreply, %{state | ships: new_ships}}
  end

  def handle_cast({:release_ship, ship_id}, state) do
    new_ships = Map.update!(state.ships, ship_id, &%{&1 | status: "idle"})
    {:noreply, %{state | ships: new_ships}}
  end

  # --- Info ---

  def handle_info({:recovery_complete, ship_id}, state) do
    case Map.get(state.ships, ship_id) do
      %{status: "recovering"} = ship ->
        max_hull = Map.get(ship.stats, "hull_max", 100)

        Store.set_ship_idle(ship_id)
        Store.update_ship_hull(ship_id, max_hull)

        # Переприменяем модули (уже в state) — без лишнего DB-запроса
        new_ship =
          %{ship | status: "idle", available_at: nil, current_hull: max_hull}
          |> recalc_stats()

        broadcast_ready(state.guild_id, ship)
        {:noreply, %{state | ships: Map.put(state.ships, ship_id, new_ship)}}

      _ ->
        {:noreply, state}
    end
  end

  # Persist по таймеру — полный snapshot всех кораблей
  def handle_info(:persist, %{dirty: false} = state) do
    schedule_persist()
    {:noreply, state}
  end

  def handle_info(:persist, %{dirty: true} = state) do
    snapshot = build_snapshot(state)
    parent = self()

    Task.start(fn ->
      result = Store.save_hangar_snapshot(snapshot)
      send(parent, {:persist_done, result})
    end)

    schedule_persist()
    # dirty: true пока не придёт :persist_done
    {:noreply, state}
  end

  def handle_info({:persist_done, :ok}, state),
    do: {:noreply, %{state | dirty: false}}

  def handle_info({:persist_done, {:error, reason}}, state) do
    Logger.error("Hangar persist failed for #{state.guild_id}: #{inspect(reason)}")
    {:noreply, state}
  end

  # --- Guards ---

  defp check_ship_owner(%{user_id: uid}, user_id) when uid == user_id, do: :ok
  defp check_ship_owner(_, _), do: {:error, :not_your_ship}

  defp check_ship_idle(%{status: "idle"}), do: :ok
  defp check_ship_idle(_), do: {:error, :ship_not_idle}

  # Считаем слоты по installed_modules в state — без запроса к БД
  defp check_slots_available(%{slots_total: total, installed_modules: mods}),
    do: if(length(mods) < total, do: :ok, else: {:error, :no_slots_available})

  # Проверяем категорию по state — без запроса к БД
  defp check_category_unique(%{installed_modules: mods}, category) do
    if Enum.any?(mods, &(&1.category == category)),
      do: {:error, :category_already_installed},
      else: :ok
  end

  defp check_module_installed(%{installed_modules: mods}, module_id) do
    if Enum.any?(mods, &(&1.id == module_id)),
      do: :ok,
      else: {:error, :module_not_installed}
  end

  defp next_free_slot(%{installed_modules: mods, slots_total: total}) do
    used = MapSet.new(mods, & &1.slot_index)
    Enum.find(0..(total - 1), &(not MapSet.member?(used, &1)))
  end

  # --- Helpers ---
  defp build_snapshot(state) do
    ships_data = state.ships |> Map.values() |> Enum.map(&ship_to_persist/1)
    %{guild_id: state.guild_id, level: state.level, ships: ships_data}
  end

  # Сохраняем только персистентные поля, не эффективные stats
  defp ship_to_persist(ship) do
    %{
      id: ship.id,
      status: ship.status,
      current_hull: ship.current_hull,
      available_at: ship.available_at,
      installed_modules: Enum.map(ship.installed_modules, & &1.id)
    }
  end

  defp get_module_def(module_id) do
    case Store.get_module_def(module_id) do
      nil -> {:error, :module_not_found}
      mod -> {:ok, mod}
    end
  end

  # Обновляем ship в памяти: добавляем модуль, пересчитываем stats
  defp apply_new_module(ship, mod_def, slot_index) do
    mod_with_slot = Map.put(mod_def, :slot_index, slot_index)
    new_modules = [mod_with_slot | ship.installed_modules]
    new_stats = Bulkhead.Game.ModuleEngine.apply_modules(ship.base_stats, new_modules)
    %{ship | installed_modules: new_modules, stats: new_stats}
  end

  defp remove_module_and_recalc(ship, module_id) do
    new_modules = Enum.reject(ship.installed_modules, &(&1.id == module_id))
    new_stats = Bulkhead.Game.ModuleEngine.apply_modules(ship.base_stats, new_modules)
    %{ship | installed_modules: new_modules, stats: new_stats}
  end

  # Пересчёт stats без изменения модулей (после recovery)
  defp recalc_stats(ship) do
    new_stats = Bulkhead.Game.ModuleEngine.apply_modules(ship.base_stats, ship.installed_modules)
    %{ship | stats: new_stats}
  end

  defp schedule_recovery_check(ship_id, available_at) do
    delay = DateTime.diff(available_at, DateTime.utc_now(), :millisecond)
    Process.send_after(self(), {:recovery_complete, ship_id}, max(0, delay))
  end

  defp index_by_id(ships), do: Map.new(ships, &{&1.id, &1})
  defp via(guild_id), do: {:via, Registry, {Bulkhead.Registry, {:hangar, guild_id}}}
  defp schedule_persist(), do: Process.send_after(self(), :persist, 60_000)

  defp broadcast_ready(guild_id, ship) do
    Phoenix.PubSub.broadcast(
      Bulkhead.PubSub,
      "station:#{guild_id}",
      {:ship_ready, %{ship_id: ship.id, ship_name: ship.name}}
    )
  end
end
