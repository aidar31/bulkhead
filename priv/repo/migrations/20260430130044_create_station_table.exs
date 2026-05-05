defmodule Bulkhead.Repo.Migrations.CreateStationTable do
  use Ecto.Migration

  def change do
    create table(:stations, primary_key: false) do
      add :guild_id, :bigint, primary_key: true
      add :resources, :map, default: %{}
      add :metadata, :map, default: %{}
      timestamps()
    end

    # create index(:stations, [], using: :gin, name: :stations_resources_gin)
    create index(:stations, [:resources], using: :gin)
  end
end
