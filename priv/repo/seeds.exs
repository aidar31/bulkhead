modules = [
  # ARMOR
  %{
    id: "heavy_plating",
    name: "Тяжёлая броня",
    description: "Усиленные плиты корпуса. Медленнее, но живучее.",
    category: "armor",
    rarity: "common",
    effects: %{"hull_max" => %{"op" => "add", "value" => 30}},
    cost: %{"scrap" => 40}
  },
  %{
    id: "nanobots",
    name: "Нанороботы",
    description: "Постепенно восстанавливают корпус во время полёта.",
    category: "armor",
    rarity: "rare",
    # +2% hull каждый тик
    effects: %{"hull_regen_pct" => %{"op" => "add", "value" => 0.02}},
    cost: %{"scrap" => 80, "credits" => 50}
  },

  # ENGINE
  %{
    id: "overdrive_engine",
    name: "Форсажный движок",
    description: "Увеличивает скорость, но корпус греется.",
    category: "engine",
    rarity: "common",
    effects: %{
      "speed" => %{"op" => "add", "value" => 5},
      # пассивный урон выше
      "passive_damage_chance" => %{"op" => "add", "value" => 10}
    },
    cost: %{"scrap" => 50}
  },
  %{
    id: "warp_stabilizer",
    name: "Варп-стабилизатор",
    description: "Сокращает дистанцию миссии — эффективнее маршрут.",
    category: "engine",
    rarity: "rare",
    effects: %{"distance_modifier" => %{"op" => "mul", "value" => 0.8}},
    cost: %{"credits" => 120}
  },

  # CARGO
  %{
    id: "expanded_hold",
    name: "Расширенный трюм",
    description: "Больше места для добычи.",
    category: "cargo",
    rarity: "common",
    effects: %{"cargo" => %{"op" => "add", "value" => 40}},
    cost: %{"scrap" => 30}
  },
  %{
    id: "ore_scanner",
    name: "Рудный сканер",
    description: "Повышает выход скрапа с событий.",
    category: "cargo",
    rarity: "rare",
    effects: %{"scrap_yield_modifier" => %{"op" => "mul", "value" => 1.3}},
    cost: %{"scrap" => 60, "credits" => 40}
  },

  # SPECIAL
  %{
    id: "stealth_field",
    name: "Поле невидимости",
    description: "Снижает шанс враждебных событий.",
    category: "special",
    rarity: "epic",
    effects: %{"hostile_event_chance" => %{"op" => "mul", "value" => 0.5}},
    cost: %{"credits" => 200}
  },
  %{
    id: "emergency_beacon",
    name: "Аварийный маяк",
    description: "При уничтожении корабль автоматически возвращается с 20% hull.",
    category: "special",
    rarity: "rare",
    effects: %{"prevent_destruction" => %{"op" => "set", "value" => true}},
    cost: %{"scrap" => 100, "credits" => 80}
  }
]

alias Bulkhead.{Repo, Game.ShipModuleDefinition}

Enum.each(modules, fn attrs ->
  %ShipModuleDefinition{}
  |> ShipModuleDefinition.changeset(attrs)
  |> Repo.insert!(on_conflict: :replace_all, conflict_target: :id)
end)
