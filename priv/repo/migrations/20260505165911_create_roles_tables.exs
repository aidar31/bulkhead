defmodule Bulkhead.Repo.Migrations.CreateRolesTables do
  use Ecto.Migration

  def change do
    # Таблица определений ролей
    create table(:role_definitions, primary_key: false) do
      add :id, :string, primary_key: true
      # nil для системных ролей
      add :guild_id, :bigint
      add :name, :string, null: false
      add :description, :text
      add :icon, :string
      add :color, :integer
      add :is_custom, :boolean, default: false
      add :effects, :map, default: "{}"
      add :constraints, :map, default: "{}"

      timestamps()
    end

    create index(:role_definitions, [:guild_id])

    # Таблица назначений ролей игрокам
    create table(:player_roles) do
      add :guild_id, :bigint, null: false
      add :user_id, :bigint, null: false
      add :role_id, :string, null: false
      add :assigned_by, :bigint
      add :expires_at, :utc_datetime

      timestamps()
    end

    create index(:player_roles, [:guild_id])
    create index(:player_roles, [:user_id])

    # Уникальный индекс, чтобы нельзя было навесить одну роль дважды
    create unique_index(:player_roles, [:guild_id, :user_id, :role_id])
  end
end
