defmodule Bulkhead.Game.Ship do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ships" do
    field :guild_id, :integer
    field :user_id, :integer
    field :name, :string
    field :type, :string
    field :status, :string, default: "idle"
    field :slots_total, :integer
    field :stats, :map, default: %{}
    field :current_hull, :float, default: 100.0
    field :available_at, :utc_datetime

    field :metadata, :map,
      default: %{
        "equipped_modules" => [],
        "experience" => 0
      }

    belongs_to :station, Bulkhead.Game.Station,
      foreign_key: :guild_id,
      references: :guild_id,
      define_field: false

    has_many :installations, Bulkhead.Game.ShipModuleInstallation, foreign_key: :ship_id

    many_to_many :installed_modules, Bulkhead.Game.ShipModuleDefinition,
      join_through: Bulkhead.Game.ShipModuleInstallation,
      # module_id: :id — это :id ShipModuleDefinition
      join_keys: [ship_id: :id, module_id: :id]

    # отдельное место под расчетные данные,
    # которые НЕ хранятся в БД
    field :temp_effective_stats, :map, virtual: true

    timestamps()
  end

  @base_stats %{
    "scout" => %{"speed" => 15, "cargo" => 30, "hull_max" => 80},
    "freighter" => %{"speed" => 7, "cargo" => 100, "hull_max" => 120},
    "combat" => %{"speed" => 10, "cargo" => 20, "hull_max" => 150}
  }

  def changeset(ship, attrs) do
    ship
    |> cast(attrs, [
      :guild_id,
      :user_id,
      :name,
      :type,
      :status,
      :stats,
      :current_hull,
      :available_at,
      :metadata
    ])
    |> validate_required([:guild_id, :user_id, :name, :type])
    |> put_base_stats()
  end

  def available?(ship) do
    ship.status == "idle" ||
      (ship.status == "recovering" &&
         DateTime.compare(DateTime.utc_now(), ship.available_at) == :gt)
  end

  def get_effective_stats(ship) do
    base = ship.stats
    # modules = ship.metadata["equipped_modules"] || []

    base
  end

  defp put_base_stats(changeset) do
    type = get_field(changeset, :type)

    if base = @base_stats[type] do
      update_change(changeset, :stats, fn custom ->
        Map.merge(base, custom || %{})
      end)
    else
      changeset
    end
  end
end
