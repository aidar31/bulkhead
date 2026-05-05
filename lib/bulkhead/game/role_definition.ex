defmodule Bulkhead.Game.RoleDefinition do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "role_definitions" do
    # nil = системная роль (для всех гильдий)
    field :guild_id, :integer
    field :name, :string
    field :description, :string
    # эмодзи
    field :icon, :string
    # Discord embed color
    field :color, :integer
    field :is_custom, :boolean, default: false

    # Эффекты роли — сюда добавляешь что угодно без миграций
    # %{
    #   "recovery_speed_bonus" => 0.5,   # +50% скорость восстановления кораблей
    #   "mission_reward_bonus" => 0.2,   # +20% к наградам миссий
    #   "research_speed_bonus" => 1.0,   # x2 скорость исследований
    #   "can_repair_ships" => true,       # может чинить корабли
    #   "can_start_missions" => true,
    #   "can_manage_modules" => true,
    #   "reactor_efficiency_bonus" => 0.1
    # }
    field :effects, :map, default: %{}

    # Ограничения
    # %{"max_per_guild" => 2, "requires_role" => "pilot"}
    field :constraints, :map, default: %{}

    timestamps()
  end

  @valid_effects ~w(
    recovery_speed_bonus
    mission_reward_bonus
    mission_success_bonus
    research_speed_bonus
    reactor_efficiency_bonus
    can_repair_ships
    can_start_missions
    can_manage_modules
    can_manage_roles
    can_upgrade_buildings
  )

  def changeset(role, attrs) do
    role
    |> cast(attrs, [
      :id,
      :guild_id,
      :name,
      :description,
      :icon,
      :color,
      :is_custom,
      :effects,
      :constraints
    ])
    |> validate_required([:id, :name, :effects])
    |> validate_effects()
  end

  defp validate_effects(changeset) do
    effects = get_field(changeset, :effects) || %{}
    unknown = Map.keys(effects) -- @valid_effects

    if unknown == [] do
      changeset
    else
      add_error(changeset, :effects, "unknown effects: #{inspect(unknown)}")
    end
  end
end
