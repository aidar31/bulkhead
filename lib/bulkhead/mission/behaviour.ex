defmodule Bulkhead.Mission.Behaviour do
  @type mission_state :: map()
  @type tick_result ::
          {:continue, mission_state()}
          | {:event, event :: map(), mission_state()}
          | {:complete, rewards :: map(), mission_state()}
          | {:failed, reason :: atom(), mission_state()}

  @doc "Начальный стейт миссии. Вызывается один раз при старте."
  @callback init(args :: map()) :: mission_state()

  @doc "Вызывается каждый тик. Вся логика прогресса здесь."
  @callback tick(mission_state()) :: tick_result()

  @doc "Игрок выбрал действие в событии."
  @callback handle_action(action :: map(), mission_state()) :: mission_state()

  @doc "Что показывать игроку прямо сейчас."
  @callback render(mission_state()) :: map()

  @doc "Сколько времени между тиками для этого типа миссии."
  @callback tick_interval() :: non_neg_integer()

  # Новое — валидация перед стартом
  # Expedition требует корабль, Defend требует корабль + спутник в секторе
  # Возвращает :ok или {:error, reason} который показывается игроку
  @callback validate_start(args :: map()) :: :ok | {:error, atom()}

  # Новое — человекочитаемые названия для ошибок и UI
  @callback mission_name() :: String.t()

  @optional_callbacks validate_start: 1
end
