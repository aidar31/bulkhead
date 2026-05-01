defmodule BulkheadBot.Context do
  alias Bulkhead.Station.Supervisor, as: StationSup

  def with_guild(interaction, fun) do
    guild_id = interaction.guild_id

    case StationSup.start_guild_services(guild_id) do
      {:ok, _pid} ->
        fun.(guild_id)

      {:error, {:already_started, _pid}} ->
        fun.(guild_id)

      {:error, reason} ->
        Nostrum.Api.Interaction.create_response(interaction, %{
          type: 4,
          data: %{content: "🚀 Станция не отвечает: #{inspect(reason)}"}
        })
    end
  end
end
