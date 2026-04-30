defmodule Bulkhead.Repo.Migrations.CreateBuildings do
  use Ecto.Migration

  def change do
    create table(:buildings) do
      add :guild_id, :bigint, null: false
      add :type, :string, null: false
      add :level, :integer, default: 1, null: false
      add :status, :string, default: "active"
      add :metadata, :map, default: %{}
      timestamps()
    end

    create unique_index(:buildings, [:guild_id, :type])
    create index(:buildings, [:guild_id])
  end
end
