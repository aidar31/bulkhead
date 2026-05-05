defmodule Bulkhead.RoleServer do
  use GenServer
  require Logger

  alias Bulkhead.Repo
  alias Bulkhead.Game.{RoleDefinition, PlayerRole, RoleEngine}
  import Ecto.Query

  def start_link(args) do
    guild_id = Keyword.fetch!(args, :guild_id)
    GenServer.start_link(__MODULE__, args, name: via(guild_id))
  end

  # --- Public API ---

  def get_player_effects(guild_id, user_id) do
    GenServer.call(via(guild_id), {:get_player_effects, user_id})
  end

  def get_player_roles(guild_id, user_id) do
    GenServer.call(via(guild_id), {:get_player_roles, user_id})
  end

  def assign_role(guild_id, user_id, role_id, assigned_by) do
    GenServer.call(via(guild_id), {:assign_role, user_id, role_id, assigned_by})
  end

  def remove_role(guild_id, user_id, role_id) do
    GenServer.call(via(guild_id), {:remove_role, user_id, role_id})
  end

  def can?(guild_id, user_id, permission) do
    effects = get_player_effects(guild_id, user_id)
    RoleEngine.can?(effects, permission)
  end

  def list_roles(guild_id) do
    GenServer.call(via(guild_id), :list_roles)
  end

  def create_custom_role(guild_id, attrs) do
    GenServer.call(via(guild_id), {:create_custom_role, attrs})
  end

  # --- Callbacks ---

  def init(args) do
    guild_id = Keyword.fetch!(args, :guild_id)

    state = %{
      guild_id: guild_id,
      # role_id => RoleDefinition
      role_defs: %{},
      # user_id => [role_id]
      player_roles: %{},
      # user_id => merged_effects (кэш)
      effects_cache: %{}
    }

    {:ok, state, {:continue, :load}}
  end

  def handle_continue(:load, state) do
    # Загружаем все определения ролей (системные + кастомные гильдии)
    role_defs =
      from(r in RoleDefinition,
        where: is_nil(r.guild_id) or r.guild_id == ^state.guild_id
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    # Загружаем назначения игроков (фильтруем истёкшие)
    player_roles =
      from(pr in PlayerRole,
        where: pr.guild_id == ^state.guild_id,
        where: is_nil(pr.expires_at) or pr.expires_at > ^DateTime.utc_now()
      )
      |> Repo.all()
      |> Enum.group_by(& &1.user_id, & &1.role_id)

    new_state = %{
      state
      | role_defs: role_defs,
        player_roles: player_roles,
        effects_cache: build_effects_cache(player_roles, role_defs)
    }

    {:noreply, new_state}
  end

  def handle_call({:get_player_effects, user_id}, _from, state) do
    effects = Map.get(state.effects_cache, user_id, %{})
    {:reply, effects, state}
  end

  def handle_call({:get_player_roles, user_id}, _from, state) do
    role_ids = Map.get(state.player_roles, user_id, [])
    roles = Enum.map(role_ids, &Map.get(state.role_defs, &1)) |> Enum.reject(&is_nil/1)
    {:reply, roles, state}
  end

  def handle_call({:assign_role, user_id, role_id, assigned_by}, _from, state) do
    with {:ok, role_def} <- fetch_role_def(state, role_id),
         :ok <- check_constraint(state, role_def) do
      result =
        Repo.insert(
          %PlayerRole{
            guild_id: state.guild_id,
            user_id: user_id,
            role_id: role_id,
            assigned_by: assigned_by
          },
          on_conflict: :nothing,
          conflict_target: [:guild_id, :user_id, :role_id]
        )

      case result do
        {:ok, _} ->
          new_player_roles =
            Map.update(state.player_roles, user_id, [role_id], &Enum.uniq([role_id | &1]))

          new_cache =
            rebuild_user_cache(user_id, new_player_roles, state.role_defs, state.effects_cache)

          broadcast_role_change(state.guild_id, user_id, :assigned, role_def)

          {:reply, {:ok, role_def},
           %{state | player_roles: new_player_roles, effects_cache: new_cache}}

        {:error, _} = err ->
          {:reply, err, state}
      end
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:remove_role, user_id, role_id}, _from, state) do
    Repo.delete_all(
      from pr in PlayerRole,
        where:
          pr.guild_id == ^state.guild_id and
            pr.user_id == ^user_id and
            pr.role_id == ^role_id
    )

    new_player_roles = Map.update(state.player_roles, user_id, [], &List.delete(&1, role_id))

    new_cache =
      rebuild_user_cache(user_id, new_player_roles, state.role_defs, state.effects_cache)

    {:reply, :ok, %{state | player_roles: new_player_roles, effects_cache: new_cache}}
  end

  def handle_call(:list_roles, _from, state) do
    {:reply, Map.values(state.role_defs), state}
  end

  # Создание кастомной роли прямо из бота/админки
  def handle_call({:create_custom_role, attrs}, _from, state) do
    role_attrs = Map.merge(attrs, %{"guild_id" => state.guild_id, "is_custom" => true})

    case %RoleDefinition{} |> RoleDefinition.changeset(role_attrs) |> Repo.insert() do
      {:ok, role_def} ->
        new_defs = Map.put(state.role_defs, role_def.id, role_def)
        {:reply, {:ok, role_def}, %{state | role_defs: new_defs}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # --- Helpers ---

  defp fetch_role_def(state, role_id) do
    case Map.get(state.role_defs, role_id) do
      nil -> {:error, :role_not_found}
      def -> {:ok, def}
    end
  end

  defp check_constraint(state, %{id: role_id} = role_def) do
    current_count =
      state.player_roles
      |> Enum.reduce(0, fn {_user_id, roles}, acc ->
        if role_id in roles, do: acc + 1, else: acc
      end)

    if RoleEngine.within_limit?(role_def, current_count) do
      :ok
    else
      {:error, :role_limit_reached}
    end
  end

  defp build_effects_cache(player_roles, role_defs) do
    Map.new(player_roles, fn {user_id, role_ids} ->
      effects =
        role_ids
        |> Enum.map(&Map.get(role_defs, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.effects)
        |> RoleEngine.merge_effects()

      {user_id, effects}
    end)
  end

  defp rebuild_user_cache(user_id, player_roles, role_defs, cache) do
    role_ids = Map.get(player_roles, user_id, [])

    effects =
      role_ids
      |> Enum.map(&Map.get(role_defs, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.effects)
      |> RoleEngine.merge_effects()

    Map.put(cache, user_id, effects)
  end

  defp broadcast_role_change(guild_id, user_id, action, role_def) do
    Phoenix.PubSub.broadcast(
      Bulkhead.PubSub,
      "station:#{guild_id}",
      {:role_changed, %{user_id: user_id, action: action, role: role_def}}
    )
  end

  defp via(guild_id), do: {:via, Registry, {Bulkhead.Registry, {:role_server, guild_id}}}
end
