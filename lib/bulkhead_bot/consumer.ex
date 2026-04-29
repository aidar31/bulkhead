defmodule BulkheadBot.Consumer do
  @behaviour Nostrum.Consumer

  def handle_event({:INTERACTION_CREATE, interaction, _ws}) do
    route_interaction(interaction)
  end

  def handle_event(_), do: :ok

  def route_interaction(%{data: %{name: "ping"}} = interaction) do
    Nostrum.Api.Interaction.create_response(interaction, %{type: 5})
    BulkheadBot.Commands.Ping.execute(interaction)
  end
end
