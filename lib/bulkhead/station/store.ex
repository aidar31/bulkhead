defmodule Bulkhead.Station.Store do
  import Ecto.Query

  alias Bulkhead.{
    Repo,
    Game,
    Game.ShipModuleDefinition,
    Game.ShipModuleInstallation
  }

  # Загружаем станцию со всеми связями сразу
  def load_or_create(guild_id) do
    case Repo.get(Game.Station, guild_id) do
      nil ->
        create_station_with_defaults(guild_id)

      station ->
        ensure_resource_defaults(station)
    end
  end

  def save(guild_id, resources, metadata \\ %{}) do
    %Game.Station{guild_id: guild_id}
    |> Game.Station.changeset(%{resources: resources, metadata: metadata})
    |> Repo.insert(
      on_conflict: {:replace, [:resources, :metadata, :updated_at]},
      conflict_target: :guild_id
    )
  end

  # Корабли
  # def get_all_ships(guild_id) do
  #   Repo.all(
  #     from s in Game.Ship,
  #       where: s.guild_id == ^guild_id,
  #       order_by: [asc: s.id]
  #   )
  # end
  def get_all_ships(guild_id) do
    # 1. Готовим запрос для загрузки определений модулей через таблицу инсталляций
    modules_query =
      from def in Game.ShipModuleDefinition,
        join: inst in Game.ShipModuleInstallation,
        on: inst.module_id == def.id,
        # Сортировка по slot_index, если это важно для логики
        order_by: [asc: inst.slot_index]

    # 2. Загружаем корабли и сразу "предзагружаем" их модули одним махом
    Repo.all(
      from s in Game.Ship,
        where: s.guild_id == ^guild_id,
        order_by: [asc: s.id],
        # Мы используем виртуальное или существующее поле для ассоциаций
        preload: [installed_modules: ^modules_query]
    )
    |> Enum.map(fn ship ->
      # 3. Применяем эффекты в памяти (уже без запросов к БД)
      effective_stats =
        Bulkhead.Game.ModuleEngine.apply_modules(ship.stats, ship.installed_modules)

      %{ship | stats: effective_stats}
    end)
  end

  def get_available_ships(guild_id) do
    now = DateTime.utc_now()

    Repo.all(
      from s in Game.Ship,
        where: s.guild_id == ^guild_id,
        where:
          s.status == "idle" or
            (s.status == "recovering" and s.available_at <= ^now)
    )
  end

  def create_starter_ship(guild_id, user_id) do
    %Bulkhead.Game.Ship{}
    |> Bulkhead.Game.Ship.changeset(%{
      guild_id: guild_id,
      user_id: user_id,
      name: "Новичок-1",
      class: "scout",
      status: "idle",
      # Даем 3 слота под твои новые модули
      slots_total: 3,
      stats: %{
        "hull_max" => 100,
        "speed" => 10,
        "firepower" => 10,
        "cargo" => 50
      }
    })
    |> Bulkhead.Repo.insert()
  end

  def find_user_ship(guild_id, user_id) do
    from(s in Bulkhead.Game.Ship,
      where: s.guild_id == ^guild_id and s.user_id == ^user_id and s.status == "idle",
      limit: 1
    )
    |> Repo.one()
  end

  # def set_ship_on_mission(ship_id) do
  #   Repo.update_all(
  #     from(s in Game.Ship, where: s.id == ^ship_id),
  #     set: [status: "on_mission", updated_at: DateTime.utc_now()]
  #   )
  # end

  # def set_ship_recovering(ship_id, hangar_level) do
  #   # Уровень ангара влияет на время восстановления
  #   recovery_minutes = max(1, 5 - hangar_level)
  #   available_at = DateTime.add(DateTime.utc_now(), recovery_minutes * 60, :second)

  #   Repo.update_all(
  #     from(s in Game.Ship, where: s.id == ^ship_id),
  #     set: [
  #       status: "recovering",
  #       available_at: available_at,
  #       updated_at: DateTime.utc_now()
  #     ]
  #   )
  # end

  def update_ship_hull(ship_id, new_hull) do
    Repo.update_all(
      from(s in Game.Ship, where: s.id == ^ship_id),
      set: [current_hull: new_hull, updated_at: DateTime.utc_now()]
    )
  end

  def install_module(ship_id, module_id, slot_index) do
    %ShipModuleInstallation{}
    |> ShipModuleInstallation.changeset(%{
      ship_id: ship_id,
      module_id: module_id,
      slot_index: slot_index
    })
    |> Repo.insert()
  end

  def get_ship_modules(ship_id) do
    Repo.all(
      from i in ShipModuleInstallation,
        where: i.ship_id == ^ship_id,
        join: d in ShipModuleDefinition,
        on: d.id == i.module_id,
        select: d
    )
  end

  def count_modules(ship_id) do
    Repo.aggregate(
      from(i in ShipModuleInstallation, where: i.ship_id == ^ship_id),
      :count
    )
  end

  # Постройки
  def get_building(guild_id, type) do
    Repo.get_by(Game.Building, guild_id: guild_id, type: type)
  end

  defp create_station_with_defaults(guild_id) do
    Repo.transaction(fn ->
      station = Repo.insert!(%Game.Station{guild_id: guild_id})

      # Создаём стартовый ангар
      Repo.insert!(%Game.Building{
        guild_id: guild_id,
        type: "hangar",
        level: 1
      })

      # Стартовый корабль
      Repo.insert!(%Game.Ship{
        guild_id: guild_id,
        name: "Ranger-01",
        type: "scout",
        stats: %{"speed" => 15, "cargo" => 30, "hull_max" => 80},
        current_hull: 80
      })

      station
    end)
    |> case do
      {:ok, station} -> station
      {:error, reason} -> raise "Failed to create station: #{inspect(reason)}"
    end
  end

  def set_ship_idle(ship_id) do
    Repo.update_all(
      from(s in Game.Ship, where: s.id == ^ship_id),
      set: [
        status: "idle",
        available_at: nil,
        updated_at: DateTime.utc_now()
      ]
    )
  end

  def set_ship_recovering(ship_id, available_at) do
    Repo.update_all(
      from(s in Bulkhead.Game.Ship, where: s.id == ^ship_id),
      set: [
        status: "recovering",
        available_at: available_at,
        updated_at: DateTime.utc_now()
      ]
    )
  end

  defp ensure_resource_defaults(station) do
    defaults = %{"spice" => 100, "scrap" => 50}
    merged = Map.merge(defaults, station.resources)

    if merged != station.resources do
      station
      |> Game.Station.changeset(%{resources: merged})
      |> Repo.update!()
    else
      station
    end
  end
end
