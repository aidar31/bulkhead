defmodule Bulkhead.Mission.Expedition do
  @behaviour Bulkhead.Mission.Behaviour

  @impl true
  def tick_interval, do: 7_000

  @impl true
  def init(_args) do
    %{
      distance: 250,
      current_pos: 0,
      hull: 100,
      scrap_collected: 0,
      last_log: "Корабль вышел на орбиту..."
    }
  end

  @impl true
  def tick(state) do
    base_speed = 10

    penalty =
      cond do
        state.hull <= 25 -> 7
        state.hull <= 50 -> 4
        true -> 0
      end

    speed = base_speed - penalty

    new_pos = state.current_pos + speed
    passive_damage = if :rand.uniform(100) <= 20, do: :rand.uniform(5) + 1, else: 0
    new_hull = state.hull - passive_damage

    cond do
      new_hull <= 0 ->
        {:failed, :hull_destroyed, %{state | hull: 0, current_pos: new_pos}}

      new_pos >= state.distance ->
        rewards = %{scrap: state.scrap_collected}
        {:complete, rewards, %{state | current_pos: new_pos}}

      state.hull <= 0 ->
        {:failed, :hull_destroyed, state}

      :rand.uniform(100) <= 45 ->
        event = random_event()
        {:event, event, %{state | current_pos: new_pos}}

      true ->
        # Небольшой пассивный износ корпуса в глубоком космосе (шанс 15%)
        wear_and_tear = if :rand.uniform(100) <= 15, do: 2, else: 0
        new_hull = state.hull - wear_and_tear

        log =
          if wear_and_tear > 0,
            do: "☢️ Радиационный фон повышен, корпус изнашивается.",
            else: random_log()

        new_state = %{state | current_pos: new_pos, hull: new_hull, last_log: log}
        {:continue, new_state}
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
    %{
      title: "🚀 Экспедиция",
      description: state.last_log,
      color: 0x00AAFF,
      fields: [
        %{name: "Прогресс", value: progress_bar(state.current_pos, state.distance)},
        %{name: "Корпус", value: "#{state.hull}%", inline: true},
        %{name: "Скрап", value: "📦 #{state.scrap_collected}", inline: true}
      ]
    }
  end

  # Random events

  defp random_event do
    case :rand.uniform(3) do
      1 -> drifting_container()
      2 -> asteroid_field()
      3 -> derelict_station()
    end
  end

  defp drifting_container do
    %{
      title: "Дрейфующий контейнер",
      description: "Обнаружен контейнер. Рискнём?",
      actions: [
        %{id: "salvage", label: "Собрать (риск)", emoji: %{name: "🚜"}},
        %{id: "ignore", label: "Пропустить", emoji: %{name: "⏭️"}},
        %{id: "repair", label: "Починиться", emoji: %{name: "🔧"}}
      ]
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

  defp derelict_station do
    %{
      title: "🛰️ Заброшенная станция",
      description: "Огромный остов станции. Можно состыковаться для ремонта или вскрыть шлюз.",
      actions: [
        %{id: "dock_repair", label: "Стыковка (Ремонт +40% 🛡️)", style: 3},
        %{id: "raid_vault", label: "Вскрыть сейф (+50 📦)", style: 1},
        %{id: "ignore", label: "Уйти", style: 2}
      ]
    }
  end

  # actions
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

  defp progress_bar(current, total) do
    filled = round(current / total * 10)

    "#{String.duplicate("🟦", filled)}#{String.duplicate("⬛", 10 - filled)} #{round(current / total * 100)}%"
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
