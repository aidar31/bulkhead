defmodule Bulkhead.Mission.Server do
  use GenServer, restart: :temporary

  # Client API

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via(args.guild_id, args.user_id))
  end

  def choose_action(guild_id, user_id, action) do
    GenServer.cast(via(guild_id, user_id), {:action, action})
  end

  def get_state(guild_id, user_id) do
    GenServer.call(via(guild_id, user_id), :get_state)
  end

  def init(args) do
    module = resolve_module(args.type)

    mission_state = module.init(args)

    state = %{
      # мета
      module: module,
      guild_id: args.guild_id,
      user_id: args.user_id,
      station_pid: args.station_pid,
      token: args.token,
      type: args.type,
      started_at: DateTime.utc_now(),
      # стейт конкретной миссии
      mission_state: mission_state,
      # :traveling | :event | :complete | :failed
      status: :traveling,
      last_activity: DateTime.utc_now()
    }

    schedule_tick(module.tick_interval())
    update_display(state)

    {:ok, state}
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

  def handle_cast({:action, action}, %{status: :event} = state) do
    new_mission_state = state.module.handle_action(action, state.mission_state)

    new_state = %{
      state
      | mission_state: new_mission_state,
        status: :traveling,
        last_activity: DateTime.utc_now()
    }

    update_display(new_state)
    {:noreply, new_state}
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

    Nostrum.Api.Interaction.edit_response(state.token, %{
      embeds: [embed],
      components: []
    })
  end

  defp show_event(state, event) do
    components = build_action_components(event.actions)

    embed =
      Map.merge(state.module.render(state.mission_state), %{
        title: "⚠️ #{event.title}",
        description: event.description,
        color: 0xFFAA00
      })

    Nostrum.Api.Interaction.edit_response(state.token, %{
      embeds: [embed],
      components: components
    })
  end

  defp finish_mission(state, rewards) do
    # Уведомляем Station с данными о корабле
    send(state.station_pid, {
      :mission_complete,
      rewards,
      %{
        ship_id: state.mission_state.ship_id,
        final_hull: state.mission_state.hull
      },
      self()
    })

    Nostrum.Api.Interaction.edit_response(state.token, %{
      embeds: [
        %{
          title: "🏁 Миссия завершена!",
          color: 0x00FF00,
          fields: rewards_to_fields(rewards)
        }
      ],
      components: []
    })
  end

  defp fail_mission(state, reason) do
    send(state.station_pid, {
      :mission_failed,
      reason,
      %{ship_id: state.mission_state.ship_id, final_hull: 0},
      self()
    })

    Nostrum.Api.Interaction.edit_response(state.token, %{
      embeds: [
        %{
          title: "💀 Миссия провалена",
          description: reason_to_string(reason),
          color: 0xFF0000
        }
      ],
      components: []
    })
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

  defp schedule_tick(interval), do: Process.send_after(self(), :tick, interval)

  defp via(guild_id, user_id) do
    {:via, Registry, {Bulkhead.Registry, {:mission, guild_id, user_id}}}
  end
end
