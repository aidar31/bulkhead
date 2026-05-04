# lib/bulkhead/mission/raid.ex
defmodule Bulkhead.Mission.Raid do
  @behaviour Bulkhead.Mission.Behaviour

  @impl true
  def tick_interval, do: 4_000

  @impl true
  def mission_name, do: "Абордаж: Грузовой Конвой"

  @impl true
  def validate_start(args) do
    participants = args[:participants] || []
    if length(participants) >= 2, do: :ok, else: {:error, :not_enough_pilots}
  end

  @impl true
  def init(args) do
    participants = args[:participants] || []

    ships =
      Enum.map(participants, fn p ->
        stats = p[:ship_stats] || %{}

        %{
          user_id: p[:user_id],
          ship_id: p[:ship_id],
          hull: p[:ship_hull] || 100,
          hull_max: Map.get(stats, "hull_max", 100),
          firepower: Map.get(stats, "attack", 10),
          prevent_destruction: Map.get(stats, "prevent_destruction", false),
          # :breacher | :gunner | :unassigned
          role: :unassigned
        }
      end)

    %{
      ships: ships,

      # Цель абордажа
      target_hull: 200,
      target_hull_max: 200,
      target_shields: 100,
      target_shields_max: 100,

      # Прогресс
      # :approach → :breach → :assault → :done
      phase: :approach,
      # 0..100 — насколько вскрыт шлюз
      breach_progress: 0,
      loot_secured: 0,

      # Флаги
      status: :loading,
      loading_ticks: 3,
      wave: 0,
      last_log: "Захватываем сигнал конвоя..."
    }
  end

  @impl true
  def tick(%{status: :loading} = state) do
    if state.loading_ticks > 1 do
      {:continue,
       %{
         state
         | loading_ticks: state.loading_ticks - 1,
           last_log: "Синхронизация экипажей... (#{state.loading_ticks - 1})"
       }}
    else
      {:continue,
       %{
         state
         | status: :active,
           phase: :approach,
           last_log: "🚨 Конвой обнаружен! Полный вперёд!"
       }}
    end
  end

  @impl true
  def tick(%{status: :active} = state) do
    case state.phase do
      :approach -> tick_approach(state)
      :breach -> tick_breach(state)
      :assault -> tick_assault(state)
    end
  end

  # --- Фаза 1: Сближение под огнём ---
  defp tick_approach(state) do
    total_firepower = sum_firepower(state.ships)
    new_wave = state.wave + 1

    # Враг бьёт по случайным кораблям
    {new_ships, hit_log} = apply_enemy_fire(state.ships, 8 + new_wave * 0.5)

    # Мы сбиваем щиты
    shield_dmg = total_firepower * 0.3
    new_shields = max(0.0, state.target_shields - shield_dmg)

    cond do
      any_ship_dead?(new_ships) ->
        handle_ship_death(state, new_ships)

      new_shields <= 0 ->
        log = "💥 Щиты конвоя пали! Начинаем стыковку!"
        event = breach_assignment_event()

        {:event, event,
         %{
           state
           | ships: new_ships,
             target_shields: 0.0,
             phase: :breach,
             wave: new_wave,
             last_log: log
         }}

      rem(new_wave, 5) == 0 ->
        event = approach_event(state)

        {:event, event,
         %{
           state
           | ships: new_ships,
             target_shields: Float.round(new_shields, 1),
             wave: new_wave,
             last_log: hit_log
         }}

      true ->
        log = "🚀 #{hit_log} Щиты: #{round(new_shields)}%"

        {:continue,
         %{
           state
           | ships: new_ships,
             target_shields: Float.round(new_shields, 1),
             wave: new_wave,
             last_log: log
         }}
    end
  end

  # --- Фаза 2: Вскрытие шлюза ---
  defp tick_breach(state) do
    # Breacher прогрессирует быстрее
    breacher_bonus = if any_role?(state.ships, :breacher), do: 20, else: 8
    gunner_protection = if any_role?(state.ships, :gunner), do: 0.5, else: 1.0

    new_breach = min(100, state.breach_progress + breacher_bonus)

    # Контратака по всем, кто не Gunner
    {new_ships, hit_log} = apply_enemy_fire(state.ships, 12 * gunner_protection)

    cond do
      any_ship_dead?(new_ships) ->
        handle_ship_death(state, new_ships)

      new_breach >= 100 ->
        log = "🔓 Шлюз вскрыт! Все внутрь!"
        event = assault_role_event()

        {:event, event,
         %{state | ships: new_ships, breach_progress: 100, phase: :assault, last_log: log}}

      true ->
        log = "🔧 #{hit_log} Взлом: #{round(new_breach)}%"
        {:continue, %{state | ships: new_ships, breach_progress: new_breach, last_log: log}}
    end
  end

  # --- Фаза 3: Штурм трюма ---
  defp tick_assault(state) do
    total_firepower = sum_firepower(state.ships)

    # Атака по цели
    hull_dmg = total_firepower * 0.5
    new_target_hull = max(0.0, state.target_hull - hull_dmg)

    # Лут накапливается
    loot_gain = 15 + if(any_role?(state.ships, :breacher), do: 10, else: 0)
    new_loot = state.loot_secured + loot_gain

    # Враг бьёт
    {new_ships, hit_log} = apply_enemy_fire(state.ships, 6)

    cond do
      any_ship_dead?(new_ships) ->
        handle_ship_death(state, new_ships)

      new_target_hull <= 0 ->
        total_scrap = round(new_loot)
        data_cores = length(state.ships) * 2
        rewards = %{scrap: total_scrap, data_cores: data_cores}

        {:complete, rewards,
         %{state | target_hull: 0.0, loot_secured: new_loot, ships: new_ships}}

      rem(state.wave + 1, 4) == 0 ->
        event = assault_event(state)

        {:event, event,
         %{
           state
           | ships: new_ships,
             target_hull: Float.round(new_target_hull, 1),
             loot_secured: new_loot,
             wave: state.wave + 1,
             last_log: hit_log
         }}

      true ->
        log = "⚔️ #{hit_log} Захвачено: #{round(new_loot)} ед."

        {:continue,
         %{
           state
           | ships: new_ships,
             target_hull: Float.round(new_target_hull, 1),
             loot_secured: new_loot,
             wave: state.wave + 1,
             last_log: log
         }}
    end
  end

  # --- Утилиты ---

  defp sum_firepower(ships) do
    Enum.reduce(ships, 0, &(&1.firepower + &2))
  end

  defp any_role?(ships, role) do
    Enum.any?(ships, &(&1.role == role))
  end

  defp any_ship_dead?(ships) do
    Enum.any?(ships, &(&1.hull <= 0))
  end

  defp apply_enemy_fire(ships, base_dmg) do
    # Случайно выбираем цель среди живых кораблей
    alive = Enum.filter(ships, &(&1.hull > 0))

    case alive do
      [] ->
        {ships, "Нет выживших."}

      _ ->
        target = Enum.random(alive)
        dmg = Float.round(base_dmg * (0.8 + :rand.uniform() * 0.4), 1)

        new_ships =
          Enum.map(ships, fn s ->
            if s.user_id == target.user_id do
              new_hull = s.hull - dmg

              # prevent_destruction: оставляем 1hp
              new_hull =
                if new_hull <= 0 and s.prevent_destruction,
                  do: 1.0,
                  else: new_hull

              %{s | hull: Float.round(new_hull, 1)}
            else
              s
            end
          end)

        log = "Корабль ##{target.ship_id} получил #{dmg} урона!"
        {new_ships, log}
    end
  end

  defp handle_ship_death(state, new_ships) do
    dead = Enum.find(new_ships, &(&1.hull <= 0))

    {:failed, :hull_destroyed,
     %{state | ships: new_ships, last_log: "💀 Корабль ##{dead.ship_id} уничтожен!"}}
  end

  # --- События ---

  defp approach_event(_state) do
    %{
      title: "Патруль конвоя",
      description: "Перехватчики конвоя атакуют! Координируйте действия:",
      actions: [
        %{id: "focus_fire", label: "Сосредоточенный огонь", style: 4, emoji: %{name: "🎯"}},
        %{id: "evasive", label: "Уклонение", style: 2, emoji: %{name: "💨"}},
        %{id: "overcharge", label: "Перегрузить орудия", style: 1, emoji: %{name: "⚡"}}
      ]
    }
  end

  defp breach_assignment_event do
    %{
      title: "Распределение ролей",
      description: """
      Щиты пали! Выберите роль для операции:
      • 🔧 **Взломщик** — ускоряет вскрытие шлюза
      • 🛡️ **Прикрытие** — снижает входящий урон во время взлома
      """,
      actions: [
        %{id: "role_breacher", label: "Взломщик", style: 1, emoji: %{name: "🔧"}},
        %{id: "role_gunner", label: "Прикрытие", style: 2, emoji: %{name: "🛡️"}}
      ]
    }
  end

  defp assault_role_event do
    %{
      title: "Внутри конвоя",
      description: "Мы внутри! Враги контратакуют. Выберите тактику:",
      actions: [
        %{id: "secure_loot", label: "Собрать груз", style: 1, emoji: %{name: "📦"}},
        %{id: "suppress", label: "Подавить охрану", style: 4, emoji: %{name: "⚔️"}},
        %{
          id: "overload_reactor",
          label: "Взорвать реактор (+урон)",
          style: 4,
          emoji: %{name: "💣"}
        }
      ]
    }
  end

  defp assault_event(_state) do
    %{
      title: "Подкрепление конвоя",
      description: "Прибыло подкрепление! Быстро решайте:",
      actions: [
        %{id: "hold_position", label: "Держать позицию", style: 2, emoji: %{name: "🛡️"}},
        %{id: "rush_bridge", label: "Рывок к рубке (+лут)", style: 1, emoji: %{name: "🏃"}},
        %{id: "evacuate", label: "Отступить с грузом", style: 3, emoji: %{name: "🚀"}}
      ]
    }
  end

  # --- Обработка действий ---
  # Важно: action приходит с user_id чтобы знать кто нажал

  @impl true
  def handle_action(%{"id" => "focus_fire", "user_id" => _uid}, state) do
    # Все корабли временно получают +50% урона (через повышение firepower на тик)
    boosted_ships = Enum.map(state.ships, &%{&1 | firepower: &1.firepower * 1.5})
    %{state | ships: boosted_ships, last_log: "🎯 Слитный залп! Урон усилен."}
  end

  def handle_action(%{"id" => "evasive", "user_id" => _uid}, state) do
    # Лечим всех на 5 (симулируем уход от урона)
    healed_ships =
      Enum.map(state.ships, fn s ->
        %{s | hull: min(s.hull_max, s.hull + 5)}
      end)

    %{state | ships: healed_ships, last_log: "💨 Манёвр уклонения! Потери минимальны."}
  end

  def handle_action(%{"id" => "overcharge", "user_id" => _uid}, state) do
    boosted_ships =
      Enum.map(state.ships, fn s ->
        %{s | firepower: s.firepower * 2.0, hull: s.hull - 10}
      end)

    %{state | ships: boosted_ships, last_log: "⚡ Орудия перегружены! Корпус трещит."}
  end

  def handle_action(%{"id" => "role_breacher", "user_id" => user_id}, state) do
    ships = assign_role(state.ships, user_id, :breacher)
    %{state | ships: ships, last_log: "🔧 Пилот #{user_id} занял позицию взломщика!"}
  end

  def handle_action(%{"id" => "role_gunner", "user_id" => user_id}, state) do
    ships = assign_role(state.ships, user_id, :gunner)
    %{state | ships: ships, last_log: "🛡️ Пилот #{user_id} прикрывает операцию!"}
  end

  def handle_action(%{"id" => "secure_loot", "user_id" => _uid}, state) do
    %{state | loot_secured: state.loot_secured + 30, last_log: "📦 Дополнительный груз погружен!"}
  end

  def handle_action(%{"id" => "suppress", "user_id" => _uid}, state) do
    %{
      state
      | target_hull: max(0, state.target_hull - 20),
        last_log: "⚔️ Охрана подавлена! Сопротивление сломлено."
    }
  end

  def handle_action(%{"id" => "overload_reactor", "user_id" => _uid}, state) do
    # Большой урон по цели, но и нам прилетает
    damaged_ships = Enum.map(state.ships, &%{&1 | hull: max(1, &1.hull - 15)})

    %{
      state
      | target_hull: max(0, state.target_hull - 60),
        ships: damaged_ships,
        last_log: "💣 Реактор взорван! Все получили урон взрывной волны."
    }
  end

  def handle_action(%{"id" => "hold_position", "user_id" => _uid}, state) do
    healed = Enum.map(state.ships, &%{&1 | hull: min(&1.hull_max, &1.hull + 8)})
    %{state | ships: healed, last_log: "🛡️ Держим линию! Медики в деле."}
  end

  def handle_action(%{"id" => "rush_bridge", "user_id" => _uid}, state) do
    %{
      state
      | loot_secured: state.loot_secured + 50,
        target_hull: max(0, state.target_hull - 30),
        last_log: "🏃 Рывок к рубке! Взяли управление и ценности."
    }
  end

  def handle_action(%{"id" => "evacuate", "user_id" => _uid}, state) do
    # Форсируем завершение с тем что есть
    rewards = %{scrap: round(state.loot_secured)}
    {:complete_now, rewards, %{state | last_log: "🚀 Отход! Груз обеспечен."}}
  end

  def handle_action(_action, state), do: state

  defp assign_role(ships, user_id, role) do
    Enum.map(ships, fn s ->
      if to_string(s.user_id) == to_string(user_id),
        do: %{s | role: role},
        else: s
    end)
  end

  # --- Рендер ---

  @impl true
  def render(%{status: :loading} = state) do
    %{
      title: "⏳ ПОДГОТОВКА АБОРДАЖА",
      color: 0xFF6600,
      description: """
      **Инициализация совместной операции...**

      📜 **БРИФИНГ:**
      1. **ЦЕЛЬ:** Захватить грузовой конвой вместе с союзниками
      2. **ФАЗЫ:** Сближение → Взлом → Штурм трюма
      3. **КООП:** Каждый игрок выбирает роль. Координация — ключ к победе!
      4. **ПРОВАЛ:** Если хоть один корабль уничтожен
      """,
      footer: %{text: "Ожидание пилотов... #{3 - state.loading_ticks}/3"}
    }
  end

  @impl true
  def render(state) do
    phase_label =
      case state.phase do
        :approach -> "🚀 Сближение"
        :breach -> "🔧 Взлом шлюза"
        :assault -> "⚔️ Штурм трюма"
      end

    target_hp_pct = round(state.target_hull / state.target_hull_max * 100)
    breach_bar = progress_bar(state.breach_progress, 100)

    ship_fields =
      Enum.map(state.ships, fn s ->
        hp_pct = round(max(0, s.hull) / s.hull_max * 100)
        role_label = role_to_string(s.role)

        %{
          name: "🚀 Корабль ##{s.ship_id} #{role_label}",
          value: "`#{hp_pct}%` #{hull_bar(hp_pct)}",
          inline: true
        }
      end)

    base_fields = [
      %{
        name: "🎯 Цель: Конвой",
        value: "Корпус: `#{target_hp_pct}%` #{hull_bar(target_hp_pct)}",
        inline: false
      }
    ]

    breach_field =
      if state.phase == :breach do
        [%{name: "🔧 Прогресс взлома", value: breach_bar, inline: false}]
      else
        []
      end

    %{
      title: "☠️ АБОРДАЖ: #{phase_label}",
      description: """
      **Последний доклад:**
      > #{state.last_log}

      📦 **Захвачено груза:** `#{round(state.loot_secured)} ед.`
      """,
      color: 0xCC2200,
      fields: base_fields ++ breach_field ++ ship_fields,
      footer: %{text: "Операция активна | Волна #{state.wave}"}
    }
  end

  defp role_to_string(:breacher), do: "🔧"
  defp role_to_string(:gunner), do: "🛡️"
  defp role_to_string(:unassigned), do: "❓"

  defp hull_bar(pct) do
    filled = round(pct / 10)
    String.duplicate("🟥", filled) <> String.duplicate("⬛", 10 - filled)
  end

  defp progress_bar(current, total) do
    ratio = min(1.0, current / total)
    filled = round(ratio * 10)
    bar = String.duplicate("🟩", filled) <> String.duplicate("⬛", 10 - filled)
    "`#{bar}` **#{round(ratio * 100)}%**"
  end
end
