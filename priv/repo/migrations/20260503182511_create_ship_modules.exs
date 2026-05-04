# Справочник всех модулей в игре
defmodule Bulkhead.Repo.Migrations.CreateShipModules do
  use Ecto.Migration

  def change do
    create table(:ship_module_definitions, primary_key: false) do
      add :id, :string, primary_key: true   # "heavy_plating", "warp_core"
      add :name, :string, null: false
      add :description, :string
      add :category, :string, null: false   # "engine" | "armor" | "cargo" | "special"
      add :rarity, :string, default: "common" # "common" | "rare" | "epic"
      add :effects, :map, default: %{}      # jsonb — эффекты модуля
      add :cost, :map, default: %{}         # %{"scrap" => 50, "credits" => 100}
      timestamps()
    end

    # Установленные модули на конкретных кораблях
    create table(:ship_module_installations) do
      add :ship_id, references(:ships, on_delete: :delete_all), null: false
      add :module_id, :string, null: false  # ссылка на definition
      add :slot_index, :integer, null: false # 0, 1, 2...
      timestamps()
    end

    create unique_index(:ship_module_installations, [:ship_id, :slot_index])
    create unique_index(:ship_module_installations, [:ship_id, :module_id])
    create index(:ship_module_installations, [:ship_id])
  end
end
