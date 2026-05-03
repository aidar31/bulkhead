defmodule Bulkhead.Mission.Expedition do
  @behaviour Bulkhead.Mission.Behaviour

  @impl true
  def tick_interval, do: 4_000

  @impl true
  def mission_name, do: "Экспедиция: Дальний Космос"

  @impl true
  def validate_start(_args) do
    # В будущем тут можно проверить что сектор под угрозой
    :ok
  end

  @impl true
  def init(args) do
    ship_stats = args[:ship_stats] || %{}

    # Характеристики берём из корабля
    hull_max = Map.get(ship_stats, "hull_max", 100)
    base_speed = Map.get(ship_stats, "speed", 10)
    cargo_capacity = Map.get(ship_stats, "cargo", 50)

    %{
      # Ship данные
      ship_id: args[:ship_id],
      ship_stats: ship_stats,

      # Берём текущий hull корабля, не 100
      hull: args[:ship_hull] || hull_max,
      hull_max: hull_max,
      base_speed: base_speed,
      cargo_capacity: cargo_capacity,

      # Миссия
      distance: 250,
      current_pos: 0,
      scrap_collected: 0,
      last_log: "Корабль вышел на орбиту..."
    }
  end

  @impl true
  def tick(state) do
    # Скорость теперь из стейта, не хардкод
    penalty =
      cond do
        state.hull <= trunc(state.hull_max * 0.25) -> 7
        state.hull <= trunc(state.hull_max * 0.50) -> 4
        true -> 0
      end

    speed = max(1, state.base_speed - penalty)
    new_pos = state.current_pos + speed

    passive_damage = if :rand.uniform(100) <= 20, do: :rand.uniform(5) + 1, else: 0
    new_hull = state.hull - passive_damage

    cond do
      new_hull <= 0 ->
        {:failed, :hull_destroyed, %{state | hull: 0, current_pos: new_pos}}

      new_pos >= state.distance ->
        rewards = %{scrap: state.scrap_collected}
        {:complete, rewards, %{state | current_pos: new_pos}}

      :rand.uniform(100) <= 35 ->
        event = random_event(state)
        {:event, event, %{state | current_pos: new_pos, hull: new_hull}}

      true ->
        wear = if :rand.uniform(100) <= 15, do: 2, else: 0
        log = if wear > 0, do: "☢️ Радиационный фон повышен.", else: random_log()

        {:continue, %{state | current_pos: new_pos, hull: new_hull - wear, last_log: log}}
    end
  end

  @impl true
  def handle_action(%{"id" => "salvage"}, state) do
    damage = :rand.uniform(15) + 5

    %{
      state
      | scrap_collected: state.scrap_collected + 15,
        hull: state.hull - damage,
        last_log: "🚜 Рискнули! Собрали скрап, но получили -#{damage}% урона."
    }
  end

  def handle_action(%{"id" => "ignore"}, state) do
    %{state | last_log: "⏭️ Прошли мимо."}
  end

  def handle_action(%{"id" => "repair"}, state) do
    %{state | hull: min(100, state.hull + 15), last_log: "🔧 Дроны починили корпус."}
  end

  @impl true
  def render(state) do
    hull_pct = round(state.hull / state.hull_max * 100)

    # Считаем примерное время прибытия для Discord Timestamp
    speed = max(1, state.base_speed - speed_penalty(state))
    remaining_dist = max(0, state.distance - state.current_pos)

    # Сколько тиков осталось (округляем вверх) * интервал в секундах
    seconds_left = ceil(remaining_dist / speed) * (tick_interval() / 1000)
    arrival_ts = System.system_time(:second) + round(seconds_left)

    status_emoji =
      cond do: (
             hull_pct > 70 -> "🟦"
             hull_pct > 30 -> "🟧"
             true -> "🟥"
           )

    description = """
    #{progress_bar(state.current_pos, state.distance)}

    **Последняя запись в бортовом журнале:**
    > #{state.last_log}

    🛰️ **Ожидаемое прибытие:** <t:#{arrival_ts}:R>
    """

    %{
      # Используем автора сообщения для персонализации (если есть user_id в стейте)
      author: %{name: "Бортовой компьютер корабля ##{state.ship_id}"},
      title: "#{status_emoji} Экспедиция в глубокий космос",
      description: description,
      color: state_color(hull_pct),
      fields: [
        %{name: "🛡️ Корпус", value: "`#{hull_pct}%`", inline: true},
        %{name: "📦 Ресурсы", value: "`#{state.scrap_collected} ед.`", inline: true},
        %{name: "🚀 Скорость", value: "`#{speed} а.е./т`", inline: true}
      ],
      footer: %{text: "Системы активны • Дистанция: #{state.current_pos}/#{state.distance} км"}
    }
  end

  def render_components(nil), do: []

  def render_components(event) do
    buttons =
      Enum.map(event.actions, fn action ->
        %{
          # BUTTON
          type: 2,
          # 1 = Primary, 2 = Secondary...
          style: Map.get(action, :style, 1),
          label: action.label,
          custom_id: action.id,
          emoji: Map.get(action, :emoji)
        }
      end)

    # Action Row
    [%{type: 1, components: buttons}]
  end

  defp speed_penalty(state) do
    hull_pct = round(state.hull / state.hull_max * 100)

    cond do
      hull_pct <= 25 -> 7
      hull_pct <= 50 -> 4
      true -> 0
    end
  end

  defp state_color(hull) do
    cond do
      # Красный
      hull <= 25 -> 0xFF5555
      # Оранжевый
      hull <= 50 -> 0xFFAA00
      # Голубой
      true -> 0x00AAFF
    end
  end

  defp calculate_speed(state) do
    base_speed = 10

    penalty =
      cond do
        state.hull <= 25 -> 7
        state.hull <= 50 -> 4
        true -> 0
      end

    base_speed - penalty
  end

  defp progress_bar(current, total) do
    ratio = current / total
    percent = round(ratio * 100)
    filled_count = round(ratio * 15)

    bar =
      String.duplicate("▬", max(0, filled_count)) <>
        "🔘" <> String.duplicate("─", max(0, 15 - filled_count))

    "`#{bar}` **#{percent}%**"
  end

  # Random events

  defp random_event(state) do
    case :rand.uniform(3) do
      1 -> drifting_container(state)
      2 -> asteroid_field()
      3 -> derelict_station(state)
    end
  end

  defp drifting_container(state) do
    # Базовые действия
    actions = [
      %{id: "salvage", label: "Собрать (риск)", emoji: %{name: "🚜"}},
      %{id: "ignore", label: "Пропустить", emoji: %{name: "⏭️"}}
    ]

    # Добавляем ремонт только если HP < 90
    actions =
      if state.hull < 90 do
        actions ++ [%{id: "repair", label: "Починиться", emoji: %{name: "🔧"}}]
      else
        # Если чиниться не надо, можно добавить альтернативу: например, усиленный поиск
        actions ++ [%{id: "salvage_extra", label: "Тщательный поиск", emoji: %{name: "🔍"}}]
      end

    %{
      title: "Дрейфующий контейнер",
      description: "Обнаружен контейнер. Что предпримем?",
      actions: actions
    }
  end

  defp asteroid_field do
    %{
      title: "☄️ Астероидное поле",
      description: "Сенсоры зашкаливают! Здесь много ресурсов, но щиты долго не выдержат.",
      actions: [
        %{id: "mine_asteroids", label: "Добыть (Риск: -20% 🛡️)", style: 4},
        %{id: "maneuver", label: "Маневрировать (Безопасно)", style: 2}
      ]
    }
  end

  defp derelict_station(state) do
    repair_action =
      if state.hull < 100 do
        %{id: "dock_repair", label: "Стыковка (Ремонт +40% 🛡️)", style: 3}
      else
        %{id: "scan_sector", label: "Сканировать сектор (+30 км)", style: 2}
      end

    %{
      title: "🛰️ Заброшенная станция",
      description: "Огромный остов станции.",
      actions: [
        repair_action,
        %{id: "raid_vault", label: "Вскрыть сейф (+50 📦)", style: 1},
        %{id: "ignore", label: "Уйти", style: 2}
      ]
    }
  end

  # actions

  def handle_action(%{"id" => "scan_sector"}, state) do
    %{
      state
      | current_pos: state.current_pos + 30,
        last_log: "📡 Сканирование позволило найти короткий путь!"
    }
  end

  def handle_action(%{"id" => "salvage_extra"}, state) do
    # Рискуем больше, но и получаем больше, раз корабль целый
    %{
      state
      | scrap_collected: state.scrap_collected + 25,
        hull: state.hull - 10,
        last_log: "🔍 Вскрыли двойное дно контейнера! Нашли ценности."
    }
  end

  # --- Логика Астероидов ---
  def handle_action(%{"id" => "mine_asteroids"}, state) do
    # Рандомный урон делает риск ощутимым
    # 11-25 урона
    damage = :rand.uniform(15) + 10
    yield = 40

    %{
      state
      | scrap_collected: state.scrap_collected + yield,
        hull: state.hull - damage,
        last_log: "💥 Астероиды помяли обшивку (-#{damage}%), но мы добыли #{yield} скрапа!"
    }
  end

  def handle_action(%{"id" => "maneuver"}, state) do
    %{state | last_log: "🧘 Аккуратно прошли сквозь камни без единой царапины."}
  end

  # --- Логика Станции ---
  def handle_action(%{"id" => "dock_repair"}, state) do
    # Большой ремонт, который имеет смысл, если ты до этого рисковал
    %{
      state
      | hull: min(100, state.hull + 40),
        last_log: "🛠️ Станция оказалась дружелюбной. Автоматика восстановила системы."
    }
  end

  def handle_action(%{"id" => "raid_vault"}, state) do
    # Большой куш, но без урона (или с небольшим за взрывчатку)
    %{
      state
      | scrap_collected: state.scrap_collected + 50,
        hull: state.hull - 5,
        last_log: "💰 Джекпот! Хранилище станции было забито ресурсами."
    }
  end

  defp random_log do
    Enum.random([
      "Сканирование секторов...",
      "Пролетаем мимо старой станции.",
      "Тишина в эфире.",
      "Входим в облако пыли."
    ])
  end
end
