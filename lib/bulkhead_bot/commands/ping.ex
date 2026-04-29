defmodule BulkheadBot.Commands.Ping do
  def execute(interaction) do
    Nostrum.Api.Interaction.edit_response(interaction, %{
      content: "Pong!"
    })
  end
end
