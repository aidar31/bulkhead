defmodule Bulkhead.Station do
  use GenServer, restart: :transient
  require Logger

  alias Bulkhead.Hangar
  alias Bulkhead.RoleServer
  alias Bulkhead.Game.{RoleDefinition, RoleEngine}

  def start_link(args) do
    guild_id = Keyword.fetch!(args, :guild_id)
    GenServer.start_link(__MODULE__, args, name: via(guild_id))
  end

  def start_mission(guild_id, mission_args) do
    case ensure_started(guild_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:start_mission, mission_args})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_coop_mission(guild_id, mission_args, participant_count) do
    case ensure_started(guild_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:start_coop_mission, mission_args, participant_count})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_status(guild_id) do
    GenServer.call(via(guild_id), :get_status)
  end

  def init(args) do
    guild_id = Keyword.fetch!(args, :guild_id)

    Phoenix.PubSub.subscribe(Bulkhead.PubSub, "station:#{guild_id}:reactor")

    state = default_state(guild_id)

    schedule_tick()
    schedule_persist()
    {:ok, state, {:continue, :load_state}}
  end

  def handle_continue(:load_state, state) do
    record = Bulkhead.Station.Store.load_or_create(state.guild_id)

    resources = %{
      credits: record.resources["credits"] || 100,
      scrap: record.resources["scrap"] || 50,
      spice: record.resources["spice"] || 50,
      energy: record.resources["energy"] || 100,
      mining_level: record.resources["mining_level"] || 1
    }

    new_state = %{
      state
      | resources: resources,
        metadata: record.metadata,
        loaded: true
    }

    {:noreply, new_state}
  end

  def handle_info(:tick, state) do
    earned = state.resources.mining_level * 2
    new_resources = %{state.resources | credits: state.resources.credits + earned}
    new_state = %{state | resources: new_resources, dirty: true}

    Phoenix.PubSub.broadcast(
      Bulkhead.PubSub,
      "station:#{state.guild_id}",
      {:tick,
       %{earned: earned, credits: new_state.resources.credits, scrap: new_state.resources.scrap}}
    )

    Logger.info(
      "Station #{state.guild_id} tick: earned #{earned} credits, total credits: #{new_state.resources.credits}"
    )

    schedule_tick()
    {:noreply, new_state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  # Missions
  # Missions
  def handle_call({:start_mission, args}, _from, state) do
    user_id = args.user_id

    with :ok <- check_reactor_online(state),
         true <-
           RoleServer.can?(state.guild_id, user_id, :can_start_missions) ||
             {:error, :no_pilot_role},
         :ok <- check_energy_sufficient(state, 20),
         [ship | _] <- Hangar.get_available_ships(state.guild_id),
         :ok <- Hangar.set_ship_on_mission(state.guild_id, ship.id),
         {:ok, pid} <- start_mission_process(state, ship, args) do
      effects = RoleServer.get_player_effects(state.guild_id, user_id)
      reward_multiplier = 1.0 + RoleEngine.bonus(effects, :mission_reward_bonus)

      new_state = %{
        state
        | active_missions: MapSet.put(state.active_missions, pid),
          multiplier: reward_multiplier,
          dirty: true
      }

      {:reply, {:ok, pid}, new_state}
    else
      {:error, :reactor_offline} ->
        {:reply, {:error, "⚡ Реактор отключён — подайте Spice!"}, state}

      {:error, :low_energy} ->
        {:reply, {:error, "🔋 Недостаточно энергии для запуска миссии"}, state}

      # Результат Hangar.get_available_ships
      [] ->
        {:reply, {:error, :no_ships_available}, state}

      # Ошибки от set_ship_on_mission или DynamicSupervisor
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_coop_mission, args, participant_count}, _from, state) do
    available = Hangar.get_available_ships(state.guild_id)

    if length(available) < participant_count do
      {:reply, {:error, :not_enough_ships}, state}
    else
      ships = Enum.take(available, participant_count)

      results =
        Enum.map(ships, fn ship ->
          Hangar.set_ship_on_mission(state.guild_id, ship.id)
          ship
        end)

      # participants приходят из args с токенами
      participants_with_ships =
        Enum.zip(args.participants, results)
        |> Enum.map(fn {p, ship} ->
          Map.merge(p, %{
            ship_id: ship.id,
            ship_stats: ship.stats,
            ship_hull: ship.current_hull
          })
        end)

      mission_args =
        Map.merge(args, %{
          participants: participants_with_ships,
          # Главный организатор (для via-ключа в Registry)
          user_id: hd(args.participants).user_id,
          token: hd(args.participants).token,
          station_pid: self()
        })

      case DynamicSupervisor.start_child(
             get_mission_sup(state.guild_id),
             {Bulkhead.Mission.Server, mission_args}
           ) do
        {:ok, pid} ->
          {:reply, {:ok, pid},
           %{state | active_missions: MapSet.put(state.active_missions, pid), dirty: true}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_info(
        {:reactor_output,
         %{
           spice_consumed: spice,
           energy_produced: energy,
           heat_produced: heat,
           status: reactor_status
         }},
        state
      ) do
    Logger.info(
      "⚡ Station #{state.guild_id}: Reactor produced #{energy} energy (consumed #{spice} spice). Heat: #{heat}"
    )

    new_resources =
      state.resources
      |> Map.update(:spice, 0, &max(0, &1 - spice))
      |> Map.update(:energy, 0, &min(&1 + energy, max_energy(state)))

    # Применяем эффект статуса реактора к зданиям
    new_state = %{state | resources: new_resources, reactor_status: reactor_status, dirty: true}

    apply_reactor_effects(new_state)
  end

  def handle_info({:spice_consumed, amount}, state) do
    new_resources = Map.update(state.resources, :spice, 0, &max(0, &1 - amount))
    {:noreply, %{state | resources: new_resources, dirty: true}}
  end

  # handle_info для кооп-завершения — ships_info теперь список
  def handle_info({:mission_complete, rewards, ships_info, _pid}, state)
      when is_list(ships_info) do
    new_resources =
      Enum.reduce(rewards, state.resources, fn {resource, amount}, acc ->
        Map.update(acc, resource, amount, &(&1 + amount))
      end)

    # Восстанавливаем все корабли
    Enum.each(ships_info, fn %{ship_id: ship_id} ->
      Hangar.start_recovery(state.guild_id, ship_id)
    end)

    {:noreply, %{state | resources: new_resources, dirty: true}}
  end

  # Старый handle_info для соло (обратная совместимость через map)
  def handle_info(
        {:mission_complete, rewards, %{ship_id: ship_id, final_hull: _hull}, _pid},
        state
      ) do
    new_resources =
      Enum.reduce(rewards, state.resources, fn {resource, amount}, acc ->
        Map.update(acc, resource, amount, &(&1 + amount))
      end)

    Hangar.start_recovery(state.guild_id, ship_id)
    {:noreply, %{state | resources: new_resources, dirty: true}}
  end

  # --- ПРОВАЛ (Co-op) ---
  def handle_info({:mission_failed, reason, lost_ships, mission_pid}, state)
      when is_list(lost_ships) do
    Logger.error("Raid Failed: #{reason}")

    Enum.each(lost_ships, fn %{ship_id: id} ->
      Hangar.start_recovery(state.guild_id, id)
      Hangar.update_ship_hull(state.guild_id, id, 10)
    end)

    {:noreply,
     %{state | active_missions: MapSet.delete(state.active_missions, mission_pid), dirty: true}}
  end

  def handle_info({:mission_failed, _reason, %{ship_id: ship_id}, _pid}, state) do
    Hangar.start_recovery(state.guild_id, ship_id)
    Hangar.update_ship_hull(state.guild_id, ship_id, 20)
    {:noreply, state}
  end

  # Persistence

  def handle_info(:persist, %{dirty: false} = state) do
    schedule_persist()
    {:noreply, state}
  end

  def handle_info(:persist, %{dirty: true} = state) do
    snapshot = {state.guild_id, state.resources, state.metadata}
    parent = self()

    Task.start(fn ->
      result = Bulkhead.Station.Store.save(snapshot)
      send(parent, {:persist_done, result})
    end)

    schedule_persist()
    # dirty остаётся true пока не придёт :persist_done
    {:noreply, state}
  end

  def handle_info({:persist_done, {:ok, _record}}, state) do
    {:noreply, %{state | dirty: false}}
  end

  def handle_info({:persist_done, {:error, changeset}}, state) do
    require Logger
    Logger.error("Failed to persist station: #{inspect(changeset.errors)}")

    {:noreply, state}
  end

  # def handle_info(:persist, state) do
  #   if state.dirty do
  #     string_resources =
  #       Map.new(state.resources, fn {k, v} -> {to_string(k), v} end)

  #     Bulkhead.Station.Store.save(state.guild_id, string_resources, state.metadata)
  #   end

  #   schedule_persist()
  #   {:noreply, %{state | dirty: false}}
  # end

  # Helpers

  defp max_energy(%{buildings_online: buildings}) do
    base = 200
    bonus = if :reactor in buildings, do: 100, else: 0
    base + bonus
  end

  defp max_energy(_state), do: 200

  defp check_reactor_online(%{reactor_status: :online}), do: :ok
  # critical — ещё можно
  defp check_reactor_online(%{reactor_status: :critical}), do: :ok
  defp check_reactor_online(_), do: {:error, :reactor_offline}

  defp check_energy_sufficient(%{resources: %{energy: e}}, cost) when e >= cost, do: :ok
  defp check_energy_sufficient(_, _), do: {:error, :low_energy}

  defp start_mission_process(state, ship, args) do
    mission_args =
      Map.merge(args, %{
        ship_id: ship.id,
        ship_stats: ship.stats,
        ship_hull: ship.current_hull,
        station_pid: self()
      })

    DynamicSupervisor.start_child(
      get_mission_sup(state.guild_id),
      {Bulkhead.Mission.Server, mission_args}
    )
  end

  # Реактор отключился — блокируем возможности
  defp apply_reactor_effects(%{reactor_status: :offline} = state) do
    # Hangar нельзя использовать без энергии
    Logger.warning("Station #{state.guild_id}: reactor offline, hangar disabled")

    Phoenix.PubSub.broadcast(
      Bulkhead.PubSub,
      "station:#{state.guild_id}",
      {:station_alert, :reactor_offline}
    )

    # только лаба без энергии
    {:noreply, %{state | buildings_online: [:laboratory]}}
  end

  defp apply_reactor_effects(%{reactor_status: :online} = state) do
    {:noreply, %{state | buildings_online: [:hangar, :factory, :laboratory, :reactor]}}
  end

  defp apply_reactor_effects(state), do: {:noreply, state}

  defp handle_rewards(state, rewards) do
    new_resources =
      Enum.reduce(rewards, state.resources, fn {resource, amount}, acc ->
        Map.update(acc, resource, amount, &(&1 + amount))
      end)

    %{state | resources: new_resources, dirty: true}
  end

  defp get_mission_sup(guild_id),
    do: {:via, Registry, {Bulkhead.Registry, {:mission_sup, guild_id}}}

  defp default_state(guild_id) do
    %{
      guild_id: guild_id,
      resources: %{
        credits: 100,
        scrap: 50,
        # теперь energy производится реактором, не статична
        energy: 0,
        # новый ресурс
        spice: 0,
        # побочный продукт реактора
        heat: 0
      },
      # ← новое поле
      reactor_status: :offline,
      # ← какие здания активны
      buildings_online: [],
      metadata: %{},
      active_missions: MapSet.new(),
      active_event: nil,
      loaded: false,
      dirty: false
    }
  end

  def whereis(guild_id), do: GenServer.whereis(via(guild_id))

  def ensure_started(guild_id) do
    case whereis(guild_id) do
      nil -> Bulkhead.Station.Supervisor.start_station(guild_id)
      pid -> {:ok, pid}
    end
  end

  defp via(guild_id), do: {:via, Registry, {Bulkhead.Registry, {:station, guild_id}}}
  defp schedule_tick(), do: Process.send_after(self(), :tick, 10_000)
  defp schedule_persist(), do: Process.send_after(self(), :persist, 60_000)
end
