defmodule BulkheadBot.Commands.StartMission do
  def execute(interaction) do
    guild_id = interaction.guild_id
    user_id = interaction.user.id

    {:ok, station_pid} = Bulkhead.Station.ensure_started(guild_id)

    case Bulkhead.Station.start_mission(guild_id, %{
           guild_id: guild_id,
           user_id: user_id,
           token: interaction.token,
           type: :expedition,
           station_pid: station_pid
         }) do
      {:ok, _id} ->
        Nostrum.Api.Interaction.edit_response(interaction, %{
          content: "🚀 Экспедиция началась!"
        })

      {:error, reason} ->
        Nostrum.Api.Interaction.edit_response(interaction, %{
          content: "❌ Ошибка: #{inspect(reason)}"
        })
    end
  end
end
