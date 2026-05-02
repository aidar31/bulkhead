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

    with_guild(interaction, fn guild_id ->
      case Hangar.get_info(guild_id) do
        %{level: level, ships: ships} ->
          embed = %{
            title: "🏗️ Ангар станции",
            description:
              "Уровень ангара: **#{level}**\nЗдесь хранятся и обслуживаются ваши корабли.",
            color: 0x5865F2,
            fields: render_ships_fields(ships)
          }

          Api.Interaction.edit_response(interaction, %{embeds: [embed]})

        _ ->
          # Если ангар еще не запущен для этой гильдии
          Api.Interaction.edit_response(interaction, %{
            content: "❌ Ангар не найден или еще загружается..."
          })
      end
    end)
  end

  # --- Helpers ---

  defp render_ships_fields(ships) do
    ships
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn ship ->
      %{
        name: "#{ship_icon(ship.type)} #{ship.name} — *#{ship.type}*",
        value: """
        Статус: **#{status_text(ship)}**
        Корпус: `#{ship.current_hull} / #{ship.stats["hull_max"] || 100}`
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
