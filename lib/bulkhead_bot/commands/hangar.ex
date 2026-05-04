defmodule BulkheadBot.Commands.Hangar do
  require Logger
  import BulkheadBot.Context
  alias Nostrum.Api
  # Наш GenServer
  alias Bulkhead.Hangar

  def execute(interaction) do
    Logger.debug(
      "command: /hangar guild_id: #{interaction.guild_id} guild_id: #{interaction.user.id} "
    )

    target_user = get_target_user(interaction)

    with_guild(interaction, fn guild_id ->
      case Hangar.get_player_ships(guild_id, target_user.id) do
        :loading ->
          Api.Interaction.edit_response(interaction, %{content: "⏳ Загрузка..."})

        [] ->
          content =
            if target_user.id == interaction.user.id,
              do: "❌ У вас пока нет кораблей.",
              else: "❌ У пользователя <@#{target_user.id}> нет кораблей."

          Api.Interaction.edit_response(interaction, %{content: content})

        ships ->
          embed = %{
            title: "🏗️ Ангар: #{target_user.username}",
            description: "Список личных кораблей в этом секторе.",
            color: 0x5865F2,
            fields: render_ships_fields(ships)
          }

          Api.Interaction.edit_response(interaction, %{embeds: [embed]})
      end
    end)
  end

  # --- Helpers ---
  defp get_target_user(interaction) do
    case interaction.data.options do
      [%{name: "target", value: user_id}] ->
        # В некоторых версиях Nostrum юзер уже в resolved,
        # но самый надежный способ — достать из мапы resolved.users
        interaction.data.resolved.users[user_id]

      _ ->
        interaction.user
    end
  end

  defp render_ships_fields(ships) do
    ships
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn ship ->
      current = round(ship.current_hull)
      max = ship.stats["hull_max"] || 100

      %{
        name: "#{ship_icon(ship.type)} #{ship.name} — *#{ship.type}*",
        value: """
        Статус: **#{status_text(ship)}**
        Корпус: `#{current} / #{max}`
        """,
        inline: false
      }
    end)
  end

  defp status_text(ship) do
    case ship.status do
      "on_mission" -> "🚀 На задании"
      "idle" -> "✅ Готов"
      "recovering" -> format_recovery_time(ship.available_at)
      "idle" -> "✅ Готов"
      _ -> "❔ Неизвестно"
    end
  end

  defp format_recovery_time(nil), do: "✅ Готов"

  defp format_recovery_time(available_at) do
    now = DateTime.utc_now()

    if DateTime.compare(available_at, now) == :gt do
      diff = DateTime.diff(available_at, now)
      # Используем Discord timestamp для живого отсчета времени!
      # <t:UNIX:R> заставит клиент Discord самого обновлять таймер
      unix = DateTime.to_unix(available_at)
      "🛠️ Ремонт (завершится <t:#{unix}:R>)"
    else
      "✅ Готов"
    end
  end

  defp ship_icon("scout"), do: "🔭"
  defp ship_icon("freighter"), do: "📦"
  defp ship_icon("combat"), do: "⚔️"
  defp ship_icon(_), do: "🛸"
end
