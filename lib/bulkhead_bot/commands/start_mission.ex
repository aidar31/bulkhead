defmodule BulkheadBot.Commands.StartMission do
  def execute(interaction, mission_type) do
    guild_id = interaction.guild_id
    user_id = interaction.user.id

    {:ok, station_pid} = Bulkhead.Station.ensure_started(guild_id)

    case Bulkhead.Station.start_mission(guild_id, %{
           guild_id: guild_id,
           user_id: user_id,
           token: interaction.token,
           type: mission_type,
           station_pid: station_pid
         }) do
      {:ok, _id} ->
        msg =
          case mission_type do
            :expedition -> "🚀 Экспедиция началась!"
            :defense -> "📡 Подготовка к обороне спутника завершена. По коням!"
            _ -> "🚀 Миссия запущена!"
          end

        Nostrum.Api.Interaction.edit_response(interaction, %{content: msg})

      {:error, reason} ->
        Nostrum.Api.Interaction.edit_response(interaction, %{
          content: "❌ Ошибка запуска: #{inspect(reason)}"
        })
    end
  end
end
