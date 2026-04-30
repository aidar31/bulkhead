defmodule Bulkhead.Repo.Migrations.CreateShips do
  use Ecto.Migration

  def change do
    create table(:ships) do
      add :guild_id, :bigint, null: false
      add :name, :string, null: false
      # "scout", "freighter", "combat"
      add :type, :string, null: false
      add :status, :string, default: "idle"
      # "idle" | "on_mission" | "recovering" | "damaged"

      # Характеристики — в jsonb пока структура нестабильна
      add :stats, :map, default: %{}
      # %{"speed" => 10, "cargo" => 50, "hull_max" => 100}

      # Текущее состояние
      add :current_hull, :integer, default: 100, null: false

      # Когда корабль освободится (recovering после миссии)
      add :available_at, :utc_datetime, null: true

      add :metadata, :map, default: %{}
      timestamps()
    end

    create index(:ships, [:guild_id])
    create index(:ships, [:guild_id, :status])
  end
end
