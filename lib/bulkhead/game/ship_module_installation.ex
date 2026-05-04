defmodule Bulkhead.Game.ShipModuleInstallation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ship_module_installations" do
    field :ship_id, :integer
    field :slot_index, :integer

    belongs_to :module_definition, Bulkhead.Game.ShipModuleDefinition,
      foreign_key: :module_id,
      references: :id,
      type: :string

    timestamps()
  end

  def changeset(inst, attrs) do
    inst
    |> cast(attrs, [:ship_id, :module_id, :slot_index])
    |> validate_required([:ship_id, :module_id, :slot_index])
    |> unique_constraint([:ship_id, :slot_index],
      message: "слот уже занят"
    )
    |> unique_constraint([:ship_id, :module_id],
      message: "модуль уже установлен"
    )
  end
end
