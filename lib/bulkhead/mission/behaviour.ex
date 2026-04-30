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
end
