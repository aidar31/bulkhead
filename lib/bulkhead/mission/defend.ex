defmodule Bulkhead.Mission.Defend do
  @behaviour Bulkhead.Mission.Behaviour

  @impl true
  def tick_interval, do: 3_000

  @impl true
  def init(args) do
    ship_stats = args[:ship_stats] || %{}

    %{
      ship_id: args[:ship_id],
      # Свойства игрока
      hull: args[:ship_hull] || 100,
      hull_max: Map.get(ship_stats, "hull_max", 100),
      firepower: Map.get(ship_stats, "attack", 10),

      # Свойства объекта защиты
      satellite_health: 100,
      satellite_max: 100,

      # Прогресс (Волны)
      wave: 1,
      max_waves: 15,
      enemies_down: 0,

      # Режим корабля: :normal, :tank (защита спутника), :assault (урон)
      mode: :normal,
      last_log: "Занимаем позицию у ретранслятора. Входящие сигналы неопознаны...",

      # Флаги
      status: :loading,
      # Сколько тиков будет висеть "Загрузка" (4 * 3 сек = 12 сек)
      loading_ticks: 4,
      last_log: "Установка связи с ретранслятором..."
    }
  end

  @impl true
  def tick(state) do
    case state.status do
      :loading ->
        if state.loading_ticks > 1 do
          new_log = "Инициализация тактического интерфейса... (#{state.loading_ticks - 1})"
          {:continue, %{state | loading_ticks: state.loading_ticks - 1, last_log: new_log}}
        else
          {:continue,
           %{
             state
             | status: :active,
               wave: 1,
               loading_ticks: 0,
               last_log: "🔥 Вторжение началось! Спутник под огнем."
           }}
        end

      :active ->
        do_battle_tick(state)
    end
  end

  defp do_battle_tick(state) do
    # 1. Возвращаем базовый урон чуть выше (золотая середина)
    base_dmg = 3 + state.wave * 0.6
    rage_factor = if state.satellite_health < 40, do: 1.4, else: 1.0

    # 2. Криты
    is_crit = state.wave > 5 and :rand.uniform(100) <= 10
    raw_damage = if is_crit, do: base_dmg * rage_factor * 1.5, else: base_dmg * rage_factor

    # 3. Распределение урона в зависимости от режима
    {ship_dmg_mod, sat_dmg_mod, kills_mod, log_prefix} =
      case state.mode do
        # Было 3 элемента, стало 4 (добавили 0.5 для kills_mod)
        :tank ->
          {1.5, 0.05, 0.5, "🛡️ Броня трещит, но вы держите удар!"}

        # Было 3 элемента, стало 4 (добавили 2.0 для kills_mod)
        :assault ->
          {0.52, 1.5, 2.0, "⚔️ Вы в яростной атаке! Спутник без защиты!"}

        # Здесь у тебя уже было 4, оставляем как есть
        _ ->
          {1.0, 1.2, 1.0, "📡 Позиционный обмен огнем."}
      end

    damaged_hull = state.hull - raw_damage * ship_dmg_mod
    damaged_sat = state.satellite_health - raw_damage * sat_dmg_mod

    kills_this_tick = state.firepower / 5 * kills_mod

    new_hull =
      if damaged_hull > 0 do
        # Добавили * 1.0 внутри round
        Float.round(min(state.hull_max, damaged_hull + state.hull_max * 0.05) * 1.0, 1)
      else
        0.0
      end

    new_sat = Float.round(damaged_sat * 1.0, 1)
    new_enemies_down = Float.round((state.enemies_down + kills_this_tick) * 1.0, 1)

    final_log = if is_crit, do: "💥 КРИТ! " <> log_prefix, else: log_prefix

    new_wave = state.wave + 1

    cond do
      new_hull <= 0 ->
        {:failed, :hull_destroyed, %{state | hull: 0}}

      new_sat <= 0 ->
        {:failed, :target_lost, %{state | satellite_health: 0}}

      new_wave > state.max_waves ->
        rewards = %{scrap: round(new_enemies_down * 10), data_cores: 3}

        {:complete, rewards,
         %{
           state
           | wave: state.max_waves,
             hull: new_hull,
             satellite_health: new_sat,
             enemies_down: new_enemies_down
         }}

        {:complete, rewards,
         %{state | wave: state.max_waves, hull: new_hull, satellite_health: new_sat}}

      rem(new_wave, 4) == 0 ->
        event = tactial_choice_event()

        {:event, event,
         %{state | wave: new_wave, hull: new_hull, satellite_health: new_sat, last_log: final_log}}

      true ->
        {:continue,
         %{
           state
           | wave: new_wave,
             hull: new_hull,
             satellite_health: new_sat,
             enemies_down: new_enemies_down,
             last_log: "#{final_log} (Волна #{new_wave})"
         }}
    end
  end

  # --- События и Экшены ---

  defp tactial_choice_event do
    %{
      title: "Перегруппировка сил",
      description:
        "Противник перестраивается. Выберите тактическую позицию на следующие несколько волн:",
      actions: [
        %{id: "mode_tank", label: "Защитник (-урон спутнику)", style: 1, emoji: %{name: "🛡️"}},
        %{id: "mode_assault", label: "Штурмовик (+урон врагу)", style: 4, emoji: %{name: "🔥"}},
        %{id: "repair_sat", label: "Починить Спутник", style: 2, emoji: %{name: "🔧"}}
      ]
    }
  end

  @impl true
  def handle_action(%{"id" => "mode_tank"}, state) do
    %{state | mode: :tank, last_log: "Вы встали в плотный защитный строй."}
  end

  def handle_action(%{"id" => "mode_assault"}, state) do
    %{
      state
      | mode: :assault,
        enemies_down: state.enemies_down + 5,
        last_log: "Орудия перегружены для максимальной мощи!"
    }
  end

  def handle_action(%{"id" => "repair_sat"}, state) do
    %{
      state
      | mode: :normal,
        satellite_health: min(100, state.satellite_health + 25),
        last_log: "Ремонтные боты восстановили щиты ретранслятора."
    }
  end

  @impl true
  def render(%{status: :loading} = state) do
    progress =
      String.duplicate("▓", 5 - state.loading_ticks) <>
        String.duplicate("░", state.loading_ticks - 1)

    %{
      title: "⏳ ЗАГРУЗКА ОПЕРАЦИИ: ЗАЩИТА",
      color: 0xFFAA00,
      image: %{url: loading_banner_url()},
      description: """
      `[#{progress}]` **Инициализация систем...**

      📜 **БРИФИНГ:**
      1. **ЦЕЛЬ:** Удержать Спутник-Ретранслятор в течение **#{state.max_waves} волн**.
      2. **ПОРАЖЕНИЕ:** Если `Hull` корабля или `HP` Спутника упадет до **0%**.
      3. **УПРАВЛЕНИЕ:** Каждые 4 волны выбирайте тактику:
         • 🛡️ **Защитник:** Прикрываете объект (урон идет по вам).
         • ⚔️ **Штурмовик:** Давите врага (урон идет по объекту).
         • 🔧 **Ремонт:** Срочное восстановление щитов Спутника.
      """,
      footer: %{text: "Подключение стабильно • Ожидание готовности пилота..."}
    }
  end

  @impl true
  def render(state) do
    ship_hp_pct = round(state.hull / state.hull_max * 100)
    sat_hp_pct = round(state.satellite_health / state.satellite_max * 100)

    # Функция для создания полоски HP
    make_bar = fn pct ->
      filled = round(pct / 10)
      String.duplicate("🟦", filled) <> String.duplicate("⬛", 10 - filled)
    end

    img_main = "https://i.ibb.co.com/wZ1FC8cY/watermarked-img-15853032489039226588.png"
    img_ship = "https://i.ibb.co.com/pvYr6G7g/watermarked-img-15853032489039228426.png"

    %{
      author: %{
        name: "СЕКТОР ##{state.ship_id} | СТАТУС: #{String.upcase(to_string(state.mode))}",
        # Маленькая иконка радара
        icon_url: "https://cdn-icons-png.flaticon.com/512/2590/2590506.png"
      },
      title: "🛰️ ОБОРОНА РЕТРАНСЛЯТОРА",
      description: """
      **Прогресс волны:** `#{state.wave} из #{state.max_waves}`

      **Последнее сообщение систем:**
      > #{state.last_log}
      """,
      color: if(ship_hp_pct < 30 or sat_hp_pct < 30, do: 0xFF0000, else: 0x5865F2),
      image: %{url: img_main},
      thumbnail: %{url: img_ship},
      fields: [
        %{
          name: "🚀 Состояние корпуса",
          value: "#{make_bar.(ship_hp_pct)}\n**#{ship_hp_pct}%**",
          inline: true
        },
        %{
          name: "📡 Целостность объекта",
          value: "#{make_bar.(sat_hp_pct)}\n**#{sat_hp_pct}%**",
          inline: true
        },
        %{
          name: "💥 Ликвидировано",
          value: "```fix\n#{state.enemies_down} ед.```",
          inline: false
        }
      ],
      footer: %{text: "🛡️ Дистанция до объекта: СТАБИЛЬНО | Операция продолжается"}
    }
  end

  defp loading_banner_url,
    do: "https://i.ibb.co.com/kgy2J0fm/image.jpg"

  def get_image_path(filename) do
    Path.join([:code.priv_dir(:bulkhead), "static", "images", "missions", "defend", filename])
  end
end
