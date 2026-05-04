defmodule Bulkhead.Game.ShipModuleDefinition do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "ship_module_definitions" do
    field :name, :string
    field :description, :string
    field :category, :string
    field :rarity, :string, default: "common"
    field :effects, :map, default: %{}
    field :cost, :map, default: %{}
    timestamps()
  end

  @categories ~w(engine armor cargo special)
  @rarities ~w(common rare epic)

  def changeset(mod, attrs) do
    mod
    |> cast(attrs, [:id, :name, :description, :category, :rarity, :effects, :cost])
    |> validate_required([:id, :name, :category])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:rarity, @rarities)
  end
end
