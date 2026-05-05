defmodule Bulkhead.Game.PlayerRole do
  use Ecto.Schema
  import Ecto.Changeset

  schema "player_roles" do
    field :guild_id, :integer
    field :user_id, :integer
    field :role_id, :string
    # user_id кто назначил
    field :assigned_by, :integer
    # nil = бессрочно
    field :expires_at, :utc_datetime

    timestamps()
  end

  def changeset(pr, attrs) do
    pr
    |> cast(attrs, [:guild_id, :user_id, :role_id, :assigned_by, :expires_at])
    |> validate_required([:guild_id, :user_id, :role_id])
    |> unique_constraint([:guild_id, :user_id, :role_id])
  end
end
