# Справочник всех модулей в игре
defmodule Bulkhead.Repo.Migrations.CreateShipModules do
  use Ecto.Migration

  def change do
    create table(:ship_module_definitions, primary_key: false) do
      # "heavy_plating", "warp_core"
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :description, :string
      # "engine" | "armor" | "cargo" | "special"
      add :category, :string, null: false
      # "common" | "rare" | "epic"
      add :rarity, :string, default: "common"
      # jsonb — эффекты модуля
      add :effects, :map, default: %{}
      # %{"scrap" => 50, "credits" => 100}
      add :cost, :map, default: %{}
      timestamps()
    end

    # Установленные модули на конкретных кораблях
    create table(:ship_module_installations) do
      add :ship_id, references(:ships, on_delete: :delete_all), null: false
      # ссылка на definition
      add :module_id, :string, null: false
      # 0, 1, 2...
      add :slot_index, :integer, null: false
      timestamps()
    end

    create unique_index(:ship_module_installations, [:ship_id, :slot_index])
    create unique_index(:ship_module_installations, [:ship_id, :module_id])
    create index(:ship_module_installations, [:ship_id])
  end
end
