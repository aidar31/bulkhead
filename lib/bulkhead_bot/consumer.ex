defmodule BulkheadBot.Consumer do
  @behaviour Nostrum.Consumer
  alias Nostrum.Struct.Interaction

  def handle_event({:READY, %{guilds: guilds}, _ws}) do
    Enum.each(guilds, fn guild ->
      register_commands(guild.id)
    end)

    IO.puts("🚀 Бот готов и команды зарегистрированы!")
  end

  def handle_event({:GUILD_AVAILABLE, guild, _ws}) do
    register_commands(guild.id)
    IO.puts("✅ Команды синхронизированы для сервера: #{guild.id}")
  end

  def handle_event({:INTERACTION_CREATE, interaction, _ws}) do
    case interaction.type do
      2 -> route_command(interaction)
      3 -> route_component(interaction)
      _ -> :ok
    end
  end

  def handle_event(_), do: :ok

  defp route_command(%Interaction{data: %{name: "ping"}} = interaction) do
    Nostrum.Api.Interaction.create_response(interaction, %{type: 5})
    BulkheadBot.Commands.Ping.execute(interaction)
  end

  defp route_command(%Interaction{data: %{name: "hangar"}} = interaction) do
    Nostrum.Api.Interaction.create_response(interaction, %{type: 5})
    BulkheadBot.Commands.Hangar.execute(interaction)
  end

  defp route_command(%Interaction{data: %{name: "start_mission", options: options}} = interaction) do
    mission_type_string = Enum.find(options, fn opt -> opt.name == "type" end).value

    Nostrum.Api.Interaction.create_response(interaction, %{type: 5})

    case mission_type_string do
      "expedition" ->
        BulkheadBot.Commands.StartMission.execute(interaction, :expedition)

      "defense" ->
        BulkheadBot.Commands.StartMission.execute(interaction, :defense)

      "mining" ->
        Nostrum.Api.Interaction.edit_response(interaction, %{
          content: "⛏️ Добыча в разработке."
        })

      _ ->
        Nostrum.Api.Interaction.edit_response(interaction, %{content: "❌ Неизвестная миссия"})
    end
  end

  defp route_command(%Interaction{data: %{name: "role", options: options}} = interaction) do
    Nostrum.Api.Interaction.create_response(interaction, %{type: 5})

    case options do
      [%{name: "list"}] ->
        BulkheadBot.Commands.Role.execute_list(interaction)

      [%{name: "info", options: opts}] ->
        target = find_option(opts, "user") || interaction.user.id
        BulkheadBot.Commands.Role.execute_info(interaction, target)

      [%{name: "assign", options: opts}] ->
        target = find_option(opts, "user")
        role_id = find_option(opts, "role")
        BulkheadBot.Commands.Role.execute_assign(interaction, target, role_id)

      [%{name: "remove", options: opts}] ->
        target = find_option(opts, "user")
        role_id = find_option(opts, "role")
        BulkheadBot.Commands.Role.execute_remove(interaction, target, role_id)
    end
  end

  defp route_command(%Interaction{data: %{name: "raid"}} = interaction) do
    Nostrum.Api.Interaction.create_response(interaction, %{type: 5})
    BulkheadBot.Commands.Raid.execute(interaction)
  end

  defp route_command(interaction) do
    :ok
  end

  defp route_component(%Interaction{data: %{custom_id: "raid_join_" <> lobby_id}} = interaction) do
    BulkheadBot.Commands.Raid.handle_join(interaction, lobby_id)
  end

  defp route_component(%Interaction{data: %{custom_id: "raid_start_" <> lobby_id}} = interaction) do
    BulkheadBot.Commands.Raid.handle_start(interaction, lobby_id)
  end

  defp route_component(%Interaction{data: %{custom_id: "raid_cancel_" <> lobby_id}} = interaction) do
    BulkheadBot.Commands.Raid.handle_cancel(interaction, lobby_id)
  end

  defp route_component(%Interaction{data: %{custom_id: "mission_" <> action_id}} = interaction) do
    Nostrum.Api.Interaction.create_response(interaction, %{type: 6})

    Bulkhead.Mission.Server.choose_action(
      interaction.guild_id,
      interaction.user.id,
      %{"id" => action_id}
    )
  end

  defp register_commands(guild_id) do
    commands = [
      %{
        name: "ping",
        description: "Проверить связь с ботом"
      },
      %{
        name: "role",
        description: "Управление ролями станции",
        options: [
          %{
            # SUB_COMMAND
            type: 1,
            name: "list",
            description: "Список всех доступных ролей"
          },
          %{
            type: 1,
            name: "info",
            description: "Посмотреть роли игрока",
            options: [
              %{type: 6, name: "user", description: "Игрок (по умолчанию — вы)", required: false}
            ]
          },
          %{
            type: 1,
            name: "assign",
            description: "Назначить роль игроку",
            options: [
              %{type: 6, name: "user", description: "Игрок", required: true},
              %{
                type: 3,
                name: "role",
                description: "Роль",
                required: true,
                choices: [
                  %{name: "🔧 Инженер", value: "engineer"},
                  %{name: "🚀 Пилот", value: "pilot"},
                  %{name: "🔬 Исследователь", value: "researcher"},
                  %{name: "⭐ Командир", value: "commander"}
                ]
              }
            ]
          },
          %{
            type: 1,
            name: "remove",
            description: "Снять роль с игрока",
            options: [
              %{type: 6, name: "user", description: "Игрок", required: true},
              %{
                type: 3,
                name: "role",
                description: "Роль",
                required: true,
                choices: [
                  %{name: "🔧 Инженер", value: "engineer"},
                  %{name: "🚀 Пилот", value: "pilot"},
                  %{name: "🔬 Исследователь", value: "researcher"},
                  %{name: "⭐ Командир", value: "commander"}
                ]
              }
            ]
          }
        ]
      },
      %{
        name: "raid",
        description: "Начать совместный рейд на грузовой конвой (2-4 пилота)"
      },
      %{
        name: "hangar",
        description: "Посмотреть список кораблей в ангаре",
        options: [
          %{
            type: 6,
            name: "target",
            description: "Чей ангар вы хотите посмотреть? (Оставьте пустым, чтобы увидеть свой)",
            required: false
          }
        ]
      },
      %{
        name: "start_mission",
        description: "Начать новую миссию",
        options: [
          %{
            type: 3,
            name: "type",
            description: "Выберите тип миссии",
            required: true,
            choices: [
              %{name: "Экспедиция", value: "expedition"},
              %{name: "🛡️ Оборона Спутника", value: "defense"},
              %{name: "⛏️ Добыча (в разработке)", value: "mining"}
            ]
          }
        ]
      }
    ]

    Enum.each(commands, fn command ->
      Nostrum.Api.ApplicationCommand.create_guild_command(guild_id, command)
    end)
  end

  defp route_component(_interaction), do: :ok

  defp find_option(opts, name) do
    case Enum.find(opts, &(&1.name == name)) do
      %{value: v} -> v
      nil -> nil
    end
  end
end
