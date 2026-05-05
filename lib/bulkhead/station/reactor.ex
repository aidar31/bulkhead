defmodule Bulkhead.Reactor do
  use GenServer
  require Logger

  # Константы реактора
  # Spice потребляется каждый цикл
  @spice_per_cycle 10
  # 30 минут
  @cycle_interval 2 * 60_000
  # Energy производится из Spice
  @energy_per_spice 50
  # Побочный продукт
  @heat_per_cycle 20

  def start_link(args) do
    guild_id = Keyword.fetch!(args, :guild_id)
    GenServer.start_link(__MODULE__, args, name: via(guild_id))
  end

  def get_status(guild_id), do: GenServer.call(via(guild_id), :get_status)

  def emergency_feed(guild_id, spice_amount),
    do: GenServer.call(via(guild_id), {:feed_spice, spice_amount})

  def init(args) do
    guild_id = Keyword.fetch!(args, :guild_id)

    state = %{
      guild_id: guild_id,
      # :online | :offline | :critical
      status: :online,
      # буфер Spice в реакторе
      spice_reserve: 0,
      # текущий output Energy за цикл
      energy_output: 0,
      # накопленное тепло (если не рассеивать — штраф)
      heat: 0,
      level: 1,
      last_cycle: DateTime.utc_now()
    }

    schedule_cycle()
    {:ok, state, {:continue, :load_state}}
  end

  def handle_continue(:load_state, state) do
    # Загружаем уровень из building record
    building = Bulkhead.Station.Store.get_building(state.guild_id, "reactor")
    level = if building, do: building.level, else: 1

    # Запрашиваем у Station текущий запас Spice
    spice = get_station_spice(state.guild_id)

    # Реактор забирает Spice на старте (буфер на 1 цикл)
    {taken, remaining} = take_spice(spice, @spice_per_cycle * level)

    notify_station(state.guild_id, {:spice_consumed, @spice_per_cycle * level - remaining})

    new_state = %{
      state
      | level: level,
        spice_reserve: taken,
        status: if(taken > 0, do: :online, else: :offline)
    }

    broadcast_status(new_state)
    {:noreply, new_state}
  end

  def handle_info(:cycle, state) do
    Logger.info("Reactor cycle for guild #{state.guild_id}, status: #{state.status}")

    # 1. Пытаемся взять Spice со станции
    spice_needed = @spice_per_cycle * state.level
    station_spice = get_station_spice(state.guild_id)

    {taken, _} = take_spice(station_spice, spice_needed)

    # 2. Определяем новый статус
    new_status =
      cond do
        taken >= spice_needed -> :online
        # частичная мощность
        taken > 0 -> :critical
        true -> :offline
      end

    # 3. Считаем output
    efficiency = taken / max(spice_needed, 1)
    energy_produced = trunc(@energy_per_spice * state.level * efficiency)
    heat_produced = trunc(@heat_per_cycle * state.level * efficiency)

    # 4. Сообщаем станции что потратили Spice и произвели Energy
    if taken > 0 do
      notify_station(
        state.guild_id,
        {:reactor_output,
         %{
           spice_consumed: taken,
           energy_produced: energy_produced,
           heat_produced: heat_produced,
           status: new_status
         }}
      )
    end

    # 5. Уведомляем игроков если статус изменился
    new_state = %{
      state
      | status: new_status,
        spice_reserve: taken,
        energy_output: energy_produced,
        heat: min(state.heat + heat_produced, 100)
    }

    if new_status != state.status do
      broadcast_status_change(new_state, state.status)
    end

    broadcast_status(new_state)
    schedule_cycle()
    {:noreply, new_state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply,
     %{
       status: state.status,
       level: state.level,
       energy_output: state.energy_output,
       heat: state.heat,
       spice_reserve: state.spice_reserve,
       next_cycle_in: next_cycle_seconds()
     }, state}
  end

  # Экстренная подача Spice (команда игрока)
  def handle_call({:feed_spice, amount}, _from, state) do
    new_state = %{state | spice_reserve: state.spice_reserve + amount, status: :online}

    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  # --- Helpers ---

  defp get_station_spice(guild_id) do
    case Bulkhead.Station.get_status(guild_id) do
      %{resources: %{spice: s}} -> s
      _ -> 0
    end
  end

  defp take_spice(available, needed) do
    taken = min(available, needed)
    {taken, needed - taken}
  end

  defp notify_station(guild_id, message) do
    # Асинхронно — реактор не ждёт станцию
    Phoenix.PubSub.broadcast(
      Bulkhead.PubSub,
      "station:#{guild_id}:reactor",
      message
    )
  end

  defp broadcast_status(state) do
    Phoenix.PubSub.broadcast(
      Bulkhead.PubSub,
      "station:#{state.guild_id}",
      {:reactor_status,
       %{
         status: state.status,
         energy_output: state.energy_output,
         heat: state.heat
       }}
    )
  end

  defp broadcast_status_change(state, old_status) do
    msg =
      case state.status do
        :offline -> "⚠️ REACTOR OFFLINE — станция теряет энергию! Нужен Spice!"
        :critical -> "🔶 Реактор на минимальной мощности (#{state.energy_output} energy)"
        :online -> "✅ Реактор снова в норме"
      end

    Phoenix.PubSub.broadcast(
      Bulkhead.PubSub,
      "guild:#{state.guild_id}:alerts",
      {:critical_alert, msg}
    )
  end

  defp schedule_cycle(), do: Process.send_after(self(), :cycle, @cycle_interval)
  defp next_cycle_seconds(), do: div(@cycle_interval, 1000)

  defp via(guild_id), do: {:via, Registry, {Bulkhead.Registry, {:reactor, guild_id}}}
end
