defmodule Bulkhead.Game.Station do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:guild_id, :integer, autogenerate: false}
  schema "stations" do
    field :resources, :map, default: %{}
    field :metadata, :map, default: %{}

    has_many :buildings, Bulkhead.Game.Building, foreign_key: :guild_id
    has_many :ships, Bulkhead.Game.Ship, foreign_key: :guild_id

    timestamps()
  end

  @default_resources %{
    "spice" => 100,
    "scrap" => 50
  }

  def changeset(station, attrs) do
    station
    |> cast(attrs, [:resources, :metadata])
    |> put_defaults()
  end

  defp put_defaults(changeset) do
    update_change(changeset, :resources, fn res ->
      Map.merge(@default_resources, res || %{})
    end)
  end
end
