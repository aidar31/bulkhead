defmodule BulkheadBot.Commands.Role do
  alias Bulkhead.{RoleServer}
  alias Bulkhead.Game.RoleEngine

  # /role list — все доступные роли и кто их занимает
  def execute_list(interaction) do
    BulkheadBot.Context.with_guild(interaction, fn guild_id ->
      roles = RoleServer.list_roles(guild_id)
      player_roles = RoleServer.get_player_roles(guild_id, interaction.user.id)

      embed = build_roles_embed(roles, player_roles, guild_id)

      Nostrum.Api.Interaction.edit_response(interaction, %{
        embeds: [embed],
        components: []
      })
    end)
  end

  # /role assign user: @user role: engineer
  def execute_assign(interaction, target_user_id, role_id) do
    BulkheadBot.Context.with_guild(interaction, fn guild_id ->
      assigner_id = interaction.user.id

      # Проверяем право назначать роли
      unless RoleServer.can?(guild_id, assigner_id, :can_manage_roles) do
        Nostrum.Api.Interaction.edit_response(interaction, %{
          embeds: [
            %{
              title: "⛔ Нет доступа",
              description: "Только **Командиры** могут назначать роли.",
              color: 0xFF0000
            }
          ]
        })

        # early return через throw чтобы не городить with
        throw(:no_permission)
      end

      case RoleServer.assign_role(guild_id, target_user_id, role_id, assigner_id) do
        {:ok, role_def} ->
          Nostrum.Api.Interaction.edit_response(interaction, %{
            embeds: [
              %{
                title: "✅ Роль назначена",
                description: """
                #{role_def.icon} **#{role_def.name}** → <@#{target_user_id}>
                """,
                color: role_def.color,
                fields: effects_to_fields(role_def.effects)
              }
            ]
          })

        {:error, :role_not_found} ->
          Nostrum.Api.Interaction.edit_response(interaction, %{
            embeds: [error_embed("Роль `#{role_id}` не найдена.")]
          })

        {:error, :role_limit_reached} ->
          Nostrum.Api.Interaction.edit_response(interaction, %{
            embeds: [error_embed("Достигнут лимит игроков с этой ролью на сервере.")]
          })

        {:error, reason} ->
          Nostrum.Api.Interaction.edit_response(interaction, %{
            embeds: [error_embed("Ошибка: #{inspect(reason)}")]
          })
      end
    end)
  catch
    :no_permission -> :ok
  end

  # /role remove user: @user role: engineer
  def execute_remove(interaction, target_user_id, role_id) do
    BulkheadBot.Context.with_guild(interaction, fn guild_id ->
      assigner_id = interaction.user.id

      unless RoleServer.can?(guild_id, assigner_id, :can_manage_roles) do
        Nostrum.Api.Interaction.edit_response(interaction, %{
          embeds: [
            %{
              title: "⛔ Нет доступа",
              description: "Только **Командиры** могут снимать роли.",
              color: 0xFF0000
            }
          ]
        })

        throw(:no_permission)
      end

      case RoleServer.remove_role(guild_id, target_user_id, role_id) do
        :ok ->
          Nostrum.Api.Interaction.edit_response(interaction, %{
            embeds: [
              %{
                title: "🗑️ Роль снята",
                description: "Роль `#{role_id}` снята с <@#{target_user_id}>.",
                color: 0x888888
              }
            ]
          })

        {:error, reason} ->
          Nostrum.Api.Interaction.edit_response(interaction, %{
            embeds: [error_embed("Ошибка: #{inspect(reason)}")]
          })
      end
    end)
  catch
    :no_permission -> :ok
  end

  # /role info — посмотреть свои роли и эффекты
  def execute_info(interaction, target_user_id) do
    BulkheadBot.Context.with_guild(interaction, fn guild_id ->
      roles = RoleServer.get_player_roles(guild_id, target_user_id)
      effects = RoleServer.get_player_effects(guild_id, target_user_id)

      embed = build_player_info_embed(target_user_id, roles, effects)

      Nostrum.Api.Interaction.edit_response(interaction, %{embeds: [embed]})
    end)
  end

  # --- UI ---

  defp build_roles_embed(all_roles, my_roles, _guild_id) do
    my_role_ids = MapSet.new(my_roles, & &1.id)

    fields =
      Enum.map(all_roles, fn role ->
        limit_text =
          case get_in(role.constraints, ["max_per_guild"]) do
            nil -> ""
            n -> " _(макс. #{n})_"
          end

        mine = if MapSet.member?(my_role_ids, role.id), do: " ✓", else: ""

        effects_text =
          role.effects
          |> Enum.map(&format_effect/1)
          |> Enum.join(", ")

        %{
          name: "#{role.icon} #{role.name}#{mine}#{limit_text}",
          value: "> #{role.description}\n> `#{effects_text}`",
          inline: false
        }
      end)

    %{
      title: "📋 Роли станции",
      color: 0x5865F2,
      fields: fields,
      footer: %{text: "✓ — ваша роль"}
    }
  end

  defp build_player_info_embed(user_id, roles, effects) do
    role_list =
      if roles == [] do
        "_Нет назначенных ролей_"
      else
        Enum.map_join(roles, "\n", fn r -> "#{r.icon} **#{r.name}**" end)
      end

    effect_list =
      if effects == %{} do
        "_Нет активных эффектов_"
      else
        effects
        |> Enum.map(&format_effect/1)
        |> Enum.join("\n")
      end

    %{
      title: "👤 Профиль игрока",
      description: "<@#{user_id}>",
      color: 0x3498DB,
      fields: [
        %{name: "Роли", value: role_list, inline: true},
        %{name: "Активные эффекты", value: effect_list, inline: true}
      ]
    }
  end

  defp effects_to_fields(effects) do
    Enum.map(effects, fn {k, v} ->
      %{name: format_effect_name(k), value: format_effect_value(v), inline: true}
    end)
  end

  defp format_effect({key, value}),
    do: "#{format_effect_name(key)}: #{format_effect_value(value)}"

  defp format_effect_name("recovery_speed_bonus"), do: "⚡ Скорость ремонта"
  defp format_effect_name("mission_reward_bonus"), do: "💰 Бонус к наградам"
  defp format_effect_name("mission_success_bonus"), do: "🎯 Шанс успеха"
  defp format_effect_name("research_speed_bonus"), do: "🔬 Скорость исследований"
  defp format_effect_name("reactor_efficiency_bonus"), do: "⚛️ КПД реактора"
  defp format_effect_name("can_repair_ships"), do: "🔧 Ремонт кораблей"
  defp format_effect_name("can_start_missions"), do: "🚀 Запуск миссий"
  defp format_effect_name("can_manage_modules"), do: "🛠️ Установка модулей"
  defp format_effect_name("can_manage_roles"), do: "👑 Управление ролями"
  defp format_effect_name("can_upgrade_buildings"), do: "🏗️ Улучшение зданий"
  defp format_effect_name(other), do: other

  defp format_effect_value(true), do: "✅"
  defp format_effect_value(false), do: "❌"
  defp format_effect_value(v) when v > 0, do: "+#{trunc(v * 100)}%"
  defp format_effect_value(v), do: "#{v}"

  defp error_embed(text) do
    %{title: "❌ Ошибка", description: text, color: 0xFF0000}
  end
end
