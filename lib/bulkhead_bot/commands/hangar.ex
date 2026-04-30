defmodule BulkheadBot.Commands.Hangar do
  alias Nostrum.Api
  alias Bulkhead.Repo
  alias Bulkhead.Game.Ship
  import Ecto.Query

  def execute(interaction) do
    guild_id = interaction.guild_id

    # ships = Repo.all(from s in Ship, where: s.guild_id == ^guild_id, order_by: [asc: s.id])
    ships = Bulkhead.Hangar.get_ships(guild_id)

    hangar = Repo.get_by(Bulkhead.Game.Building, guild_id: guild_id, type: "hangar")

    embed = %{
      title: "🏗️ Ангар станции",
      description:
        "Уровень ангара: **#{hangar.level}**\nЗдесь хранятся и обслуживаются ваши корабли.",
      color: 0x5865F2,
      fields:
        Enum.map(ships, fn ship ->
          %{
            name: "#{ship.name} (#{ship.type})",
            value: """
            Статус: **#{status_text(ship)}**
            Корпус: `#{ship.current_hull} / #{ship.stats["hull_max"]}`
            """,
            inline: false
          }
        end)
    }

    Api.Interaction.edit_response(
      interaction,
      %{embeds: [embed]}
    )
  end

  # Helpers
  def status_text(ship) do
    now = DateTime.utc_now()

    cond do
      ship.status == "on_mission" ->
        "🚀 На задании"

      ship.status == "idle" ->
        "✅ Готов"

      ship.status == "recovering" && DateTime.compare(ship.available_at, now) == :gt ->
        diff = DateTime.diff(ship.available_at, now)
        minutes = div(diff, 60)
        seconds = rem(diff, 60)
        "🛠️ Ремонт (~#{minutes}м #{seconds}с)"

      true ->
        "✅ Готов"
    end
  end
end
