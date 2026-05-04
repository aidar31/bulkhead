defmodule Bulkhead.Mission.Server do
  use GenServer, restart: :temporary

  # Client API

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via(args.guild_id, args.user_id))
  end

  def choose_action(guild_id, user_id, action) do
    GenServer.cast(via(guild_id, user_id), {:action, action, user_id})
  end

  def get_state(guild_id, user_id) do
    GenServer.call(via(guild_id, user_id), :get_state)
  end

  def init(args) do
    # Дебаг
    IO.puts("!!! MISSION SERVER STARTING FOR USER #{args.user_id} !!!")
    module = resolve_module(args.type)

    participants =
      case args[:participants] do
        nil ->
          [%{user_id: args.user_id, token: args.token}]

        list ->
          list
      end

    case function_exported?(module, :validate_start, 1) &&
           module.validate_start(args) do
      {:error, reason} ->
        {:stop, {:shutdown, {:validation_failed, reason}}}

      _ ->
        mission_state = module.init(args)

        state = %{
          module: module,
          guild_id: args.guild_id,
          # оставил для обратной совместимости
          user_id: args.user_id,
          # список всех участников с их токенами
          participants: participants,
          station_pid: args.station_pid,
          # основной токен для обратной совместимости
          token: args.token,
          type: args.type,
          started_at: DateTime.utc_now(),
          mission_state: mission_state,
          status: :traveling,
          last_activity: DateTime.utc_now()
        }

        schedule_tick(module.tick_interval())
        update_display(state)

        {:ok, state}
    end
  end

  # Тик — делегируем в модуль
  def handle_info(:tick, %{status: :event} = state) do
    # Ждём выбора игрока — тик не двигаем
    schedule_tick(state.module.tick_interval())
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    if activity_expired?(state.last_activity) do
      fail_mission(state, :timeout)
      {:stop, :normal, state}
    else
      IO.puts("""
      \n[MISSION TICK] ---------------------------------------
      Module: #{inspect(state.module)}
      Status: #{state.status}
      User:   #{state.user_id}
      State Data: #{inspect(state.mission_state, pretty: true)}
      -------------------------------------------------------
      """)

      case state.module.tick(state.mission_state) do
        {:continue, new_mission_state} ->
          new_state = %{state | mission_state: new_mission_state}
          update_display(new_state)
          schedule_tick(state.module.tick_interval())
          {:noreply, new_state}

        {:event, event, new_mission_state} ->
          new_state = %{state | mission_state: new_mission_state, status: :event}
          show_event(new_state, event)
          schedule_tick(state.module.tick_interval())
          {:noreply, new_state}

        {:complete, rewards, new_mission_state} ->
          new_state = %{state | mission_state: new_mission_state, status: :complete}
          finish_mission(new_state, rewards)
          {:stop, :normal, new_state}

        {:failed, reason, new_mission_state} ->
          new_state = %{state | mission_state: new_mission_state, status: :failed}
          fail_mission(new_state, reason)
          {:stop, :normal, new_state}
      end
    end
  end

  def handle_cast({:action, action, user_id}, %{status: :event} = state) do
    action_with_user = Map.put(action, "user_id", user_id)
    result = state.module.handle_action(action_with_user, state.mission_state)

    # handle_action может вернуть стейт ИЛИ {:complete_now, rewards, new_state}
    case result do
      {:complete_now, rewards, new_mission_state} ->
        new_state = %{state | mission_state: new_mission_state, status: :complete}
        finish_mission(new_state, rewards)
        {:stop, :normal, new_state}

      new_mission_state ->
        new_state = %{
          state
          | mission_state: new_mission_state,
            status: :traveling,
            last_activity: DateTime.utc_now()
        }

        update_display(new_state)
        {:noreply, new_state}
    end
  end

  def handle_cast({:action, _action}, state) do
    # Игрок нажал кнопку когда события уже нет — игнорим
    {:noreply, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  defp update_display(state) do
    embed = state.module.render(state.mission_state)

    Enum.each(state.participants, fn p ->
      Nostrum.Api.Interaction.edit_response(p.token, %{
        embeds: [embed],
        components: []
      })
    end)
  end

  defp show_event(state, event) do
    components = build_action_components(event.actions)

    embed =
      Map.merge(state.module.render(state.mission_state), %{
        title: "⚠️ #{event.title}",
        description: event.description,
        color: 0xFFAA00
      })

    Enum.each(state.participants, fn p ->
      Nostrum.Api.Interaction.edit_response(p.token, %{
        embeds: [embed],
        components: components
      })
    end)
  end

  defp finish_mission(state, rewards) do
    # Собираем все ship_id из участников миссии
    ships_info =
      case state.mission_state do
        %{ships: ships} ->
          Enum.map(ships, &%{ship_id: &1.ship_id, final_hull: &1.hull})

        ms ->
          [%{ship_id: ms.ship_id, final_hull: ms.hull}]
      end

    send(state.station_pid, {
      :mission_complete,
      rewards,
      ships_info,
      self()
    })

    Enum.each(state.participants, fn p ->
      Nostrum.Api.Interaction.edit_response(p.token, %{
        embeds: [
          %{
            title: "🏁 Миссия завершена!",
            color: 0x00FF00,
            fields: rewards_to_fields(rewards)
          }
        ],
        components: []
      })
    end)
  end

  defp fail_mission(state, reason) do
    ships_info =
      case state.mission_state do
        %{ships: ships} -> Enum.map(ships, &%{ship_id: &1.ship_id, final_hull: 0})
        ms -> [%{ship_id: ms.ship_id, final_hull: 0}]
      end

    send(state.station_pid, {
      :mission_failed,
      reason,
      ships_info,
      self()
    })

    Enum.each(state.participants, fn p ->
      Nostrum.Api.Interaction.edit_response(p.token, %{
        embeds: [
          %{
            title: "💀 Миссия провалена",
            description: reason_to_string(reason),
            color: 0xFF0000
          }
        ],
        components: []
      })
    end)
  end

  defp build_action_components(actions) do
    buttons =
      Enum.map(actions, fn action ->
        %{
          type: 2,
          style: action[:style] || 1,
          label: action.label,
          custom_id: "mission_#{action.id}",
          emoji: action[:emoji]
        }
      end)

    [%{type: 1, components: buttons}]
  end

  defp activity_expired?(last_time) do
    DateTime.diff(DateTime.utc_now(), last_time) > 300
  end

  defp rewards_to_fields(rewards) do
    Enum.map(rewards, fn {key, val} ->
      %{name: to_string(key), value: "#{val}", inline: true}
    end)
  end

  defp reason_to_string(:hull_destroyed), do: "Корабль уничтожен"
  defp reason_to_string(:timeout), do: "Время миссии истекло"

  defp reason_to_string(:target_lost),
    do: "Спутник-ретранслятор был уничтожен"

  defp resolve_module(:expedition), do: Bulkhead.Mission.Expedition
  defp resolve_module(:defense), do: Bulkhead.Mission.Defend
  defp resolve_module(:raid), do: Bulkhead.Mission.Raid

  defp schedule_tick(interval), do: Process.send_after(self(), :tick, interval)

  defp via(guild_id, user_id) do
    {:via, Registry, {Bulkhead.Registry, {:mission, guild_id, user_id}}}
  end
end
