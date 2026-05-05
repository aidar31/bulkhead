defmodule Bulkhead.Game.Building do
  use Ecto.Schema
  import Ecto.Changeset

  schema "buildings" do
    field :guild_id, :integer
    field :type, :string
    field :level, :integer, default: 1
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    belongs_to :station, Bulkhead.Game.Station,
      foreign_key: :guild_id,
      references: :guild_id,
      define_field: false

    timestamps()
  end

  @valid_types ~w(hangar factory laboratory reactor)

  def changeset(building, attrs) do
    building
    |> cast(attrs, [:guild_id, :type, :level, :status, :metadata])
    |> validate_required([:guild_id, :type])
    |> validate_inclusion(:type, @valid_types)
    |> validate_number(:level, greater_than: 0)
    |> unique_constraint([:guild_id, :type])
  end
end
