defmodule BulkheadBot.Commands.Ping do
  require Logger

  def execute(interaction) do
    Logger.debug(
      "Command /ping user_id: #{interaction.user.id}, guild_id: #{interaction.guild_id}"
    )

    Nostrum.Api.Interaction.edit_response(interaction, %{
      content: "Pong!"
    })
  end
end

# 773649228915277866
