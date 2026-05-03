defmodule Bulkhead.Station.Store do
  import Ecto.Query
  alias Bulkhead.{Repo, Game}

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
  def get_all_ships(guild_id) do
    Repo.all(
      from s in Game.Ship,
        where: s.guild_id == ^guild_id,
        order_by: [asc: s.id]
    )
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
