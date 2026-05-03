defmodule Bulkhead.Repo.Migrations.AddOwnerToShips do
  use Ecto.Migration

  def change do
    alter table(:ships) do
      add :user_id, :bigint, null: false
      add :slots_total, :integer, default: 2
      modify :current_hull, :float, from: :integer
    end

    create index(:ships, [:user_id])
    create index(:ships, [:user_id, :status])
  end
end
