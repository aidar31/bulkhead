defmodule Bulkhead.Game.RoleSeeds do
  alias Bulkhead.Repo
  alias Bulkhead.Game.RoleDefinition

  system_roles = [
    %{
      id: "engineer",
      name: "Инженер",
      icon: "🔧",
      color: 0x3498DB,
      description: "Специалист по обслуживанию кораблей и станции",
      effects: %{
        "recovery_speed_bonus" => 0.5,
        "can_repair_ships" => true,
        "can_manage_modules" => true,
        "reactor_efficiency_bonus" => 0.1
      },
      constraints: %{"max_per_guild" => 3}
    },
    %{
      id: "pilot",
      name: "Пилот",
      icon: "🚀",
      color: 0xE74C3C,
      description: "Опытный пилот, специализируется на миссиях",
      effects: %{
        "can_start_missions" => true,
        "mission_reward_bonus" => 0.25,
        "mission_success_bonus" => 0.15
      },
      constraints: %{}
    },
    %{
      id: "researcher",
      name: "Исследователь",
      icon: "🔬",
      color: 0x9B59B6,
      description: "Занимается развитием технологий станции",
      effects: %{
        "research_speed_bonus" => 1.0,
        "can_upgrade_buildings" => true
      },
      constraints: %{"max_per_guild" => 2}
    },
    %{
      id: "commander",
      name: "Командир",
      icon: "⭐",
      color: 0xF1C40F,
      description: "Управляет станцией и назначает роли",
      effects: %{
        "can_manage_roles" => true,
        "can_upgrade_buildings" => true,
        "can_start_missions" => true,
        "mission_reward_bonus" => 0.1
      },
      constraints: %{"max_per_guild" => 1}
    }
  ]

    Enum.each(system_roles, fn attrs ->
      %RoleDefinition{}
      |> RoleDefinition.changeset(attrs)
      |> Repo.insert(on_conflict: {:replace, [:name, :description, :effects, :constraints]},
                     conflict_target: :id)
    end)
end
