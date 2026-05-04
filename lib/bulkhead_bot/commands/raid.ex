# lib/bulkhead_bot/commands/raid.ex
defmodule BulkheadBot.Commands.Raid do
  # 2 минуты на сбор группы
  @lobby_timeout_ms 120_000
  @min_players 2
  @max_players 4

  def execute(interaction) do
    guild_id = interaction.guild_id
    leader_id = interaction.user.id
    leader_name = interaction.user.username

    # Создаём лобби в ETS / простой GenServer — или прямо в сообщении
    # Для простоты храним стейт лобби через custom_id кнопок (stateless подход)
    lobby_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    embed = build_lobby_embed(lobby_id, [%{user_id: leader_id, name: leader_name}], :waiting)

    Nostrum.Api.Interaction.edit_response(interaction, %{
      embeds: [embed],
      components: build_lobby_components(lobby_id, leader_id)
    })

    # Регистрируем лобби
    BulkheadBot.Lobby.Registry.create(lobby_id, %{
      guild_id: guild_id,
      leader_id: leader_id,
      # Храним token лидера для обновления сообщения
      leader_token: interaction.token,
      participants: [%{user_id: leader_id, name: leader_name, token: nil}],
      message_token: interaction.token
    })

    # Авто-закрытие лобби через таймаут
    Process.send_after(
      BulkheadBot.Lobby.Registry,
      {:expire_lobby, lobby_id},
      @lobby_timeout_ms
    )
  end

  # Вызывается когда кто-то жмёт "Присоединиться"
  def handle_join(interaction, lobby_id) do
    user_id = interaction.user.id
    user_name = interaction.user.username

    case BulkheadBot.Lobby.Registry.join(lobby_id, %{
           user_id: user_id,
           name: user_name,
           # Сохраняем токен чтобы потом слать эмбед этому игроку
           token: interaction.token
         }) do
      {:ok, lobby} ->
        # Подтверждаем взаимодействие (тип 6 = deferral update)
        Nostrum.Api.Interaction.create_response(interaction, %{type: 6})

        # Обновляем сообщение лобби для всех
        embed = build_lobby_embed(lobby_id, lobby.participants, :waiting)
        components = build_lobby_components(lobby_id, lobby.leader_id)

        Nostrum.Api.Interaction.edit_response(lobby.message_token, %{
          embeds: [embed],
          components: components
        })

      {:error, :already_joined} ->
        Nostrum.Api.Interaction.create_response(interaction, %{
          type: 4,
          data: %{content: "⚠️ Вы уже в этом лобби!", flags: 64}
        })

      {:error, :lobby_full} ->
        Nostrum.Api.Interaction.create_response(interaction, %{
          type: 4,
          data: %{content: "❌ Лобби заполнено!", flags: 64}
        })

      {:error, :not_found} ->
        Nostrum.Api.Interaction.create_response(interaction, %{
          type: 4,
          data: %{content: "❌ Лобби уже закрыто.", flags: 64}
        })
    end
  end

  # Вызывается когда лидер жмёт "Начать"
  def handle_start(interaction, lobby_id) do
    user_id = interaction.user.id

    case BulkheadBot.Lobby.Registry.get(lobby_id) do
      {:ok, lobby} when lobby.leader_id == user_id ->
        if length(lobby.participants) < @min_players do
          Nostrum.Api.Interaction.create_response(interaction, %{
            type: 4,
            data: %{
              content: "⚠️ Нужно минимум #{@min_players} пилота для рейда!",
              flags: 64
            }
          })
        else
          # Лидер подтверждает — его interaction обновит сообщение лобби
          Nostrum.Api.Interaction.create_response(interaction, %{type: 6})

          BulkheadBot.Lobby.Registry.close(lobby_id)
          launch_raid(interaction, lobby)
        end

      {:ok, _lobby} ->
        Nostrum.Api.Interaction.create_response(interaction, %{
          type: 4,
          data: %{content: "⛔ Только лидер может начать рейд.", flags: 64}
        })

      {:error, :not_found} ->
        Nostrum.Api.Interaction.create_response(interaction, %{
          type: 4,
          data: %{content: "❌ Лобби не найдено.", flags: 64}
        })
    end
  end

  # Вызывается когда лидер жмёт "Отменить"
  def handle_cancel(interaction, lobby_id) do
    case BulkheadBot.Lobby.Registry.get(lobby_id) do
      {:ok, lobby} when lobby.leader_id == interaction.user.id ->
        BulkheadBot.Lobby.Registry.close(lobby_id)
        Nostrum.Api.Interaction.create_response(interaction, %{type: 6})

        Nostrum.Api.Interaction.edit_response(lobby.message_token, %{
          embeds: [%{title: "❌ Рейд отменён", color: 0x888888}],
          components: []
        })

      _ ->
        Nostrum.Api.Interaction.create_response(interaction, %{
          type: 4,
          data: %{content: "⛔ Только лидер может отменить рейд.", flags: 64}
        })
    end
  end

  defp launch_raid(leader_interaction, lobby) do
    # Участники с их токенами (токен лидера — из его последнего interaction)
    participants =
      Enum.map(lobby.participants, fn p ->
        %{
          user_id: p.user_id,
          # У лидера токен из interaction, у остальных — сохранён при join
          token: if(p.user_id == lobby.leader_id, do: leader_interaction.token, else: p.token)
        }
      end)

    # Обновляем лобби-сообщение — показываем "Запуск..."
    embed = build_lobby_embed("", lobby.participants, :launching)

    Nostrum.Api.Interaction.edit_response(lobby.message_token, %{
      embeds: [embed],
      components: []
    })

    mission_args = %{
      guild_id: lobby.guild_id,
      # Лидер как "главный" для Registry-ключа
      user_id: lobby.leader_id,
      token: leader_interaction.token,
      type: :raid,
      participants: participants,
      # Station подставит сам
      station_pid: nil
    }

    case Bulkhead.Station.start_coop_mission(lobby.guild_id, mission_args, length(participants)) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Nostrum.Api.Interaction.edit_response(lobby.message_token, %{
          embeds: [
            %{
              title: "❌ Не удалось запустить рейд",
              description: "Причина: #{inspect(reason)}",
              color: 0xFF0000
            }
          ],
          components: []
        })
    end
  end

  # --- UI ---

  defp build_lobby_embed(_lobby_id, participants, status) do
    player_list =
      participants
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} -> "#{i}. <@#{p.user_id}>" end)
      |> Enum.join("\n")

    {title, color, footer} =
      case status do
        :waiting ->
          {"⚓ Лобби рейда | Ожидание пилотов...", 0x5865F2,
           "Минимум #{@min_players} • Максимум #{@max_players} пилотов"}

        :launching ->
          {"🚀 Запуск операции...", 0xFFAA00, "Готовьтесь к абордажу!"}
      end

    %{
      title: title,
      color: color,
      description: """
      **Операция:** ☠️ Абордаж грузового конвоя
      **Состав группы (#{length(participants)}/#{@max_players}):**
      #{player_list}

      📜 **Брифинг:**
      Командный рейд на вражеский конвой. Каждый пилот управляет своим кораблём.
      Координируйте роли — один взламывает, другой прикрывает.
      """,
      footer: %{text: footer}
    }
  end

  defp build_lobby_components(lobby_id, _leader_id) do
    [
      %{
        type: 1,
        components: [
          %{
            type: 2,
            style: 1,
            label: "Присоединиться",
            custom_id: "raid_join_#{lobby_id}",
            emoji: %{name: "⚓"}
          },
          %{
            type: 2,
            style: 3,
            label: "Начать рейд",
            custom_id: "raid_start_#{lobby_id}",
            emoji: %{name: "🚀"}
          },
          %{
            type: 2,
            style: 4,
            label: "Отменить",
            custom_id: "raid_cancel_#{lobby_id}",
            emoji: %{name: "❌"}
          }
        ]
      }
    ]
  end
end
