# lib/bulkhead_bot/lobby/registry.ex
defmodule BulkheadBot.Lobby.Registry do
  use GenServer

  @max_players 4

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def create(lobby_id, data),
    do: GenServer.call(__MODULE__, {:create, lobby_id, data})

  def get(lobby_id),
    do: GenServer.call(__MODULE__, {:get, lobby_id})

  def join(lobby_id, participant),
    do: GenServer.call(__MODULE__, {:join, lobby_id, participant})

  def close(lobby_id),
    do: GenServer.cast(__MODULE__, {:close, lobby_id})

  # --- Callbacks ---

  def init(_), do: {:ok, %{}}

  def handle_call({:create, lobby_id, data}, _from, state) do
    {:reply, :ok, Map.put(state, lobby_id, data)}
  end

  def handle_call({:get, lobby_id}, _from, state) do
    case Map.fetch(state, lobby_id) do
      {:ok, lobby} -> {:reply, {:ok, lobby}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:join, lobby_id, participant}, _from, state) do
    case Map.fetch(state, lobby_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, lobby} ->
        already_in = Enum.any?(lobby.participants, &(&1.user_id == participant.user_id))
        full = length(lobby.participants) >= @max_players

        cond do
          already_in ->
            {:reply, {:error, :already_joined}, state}

          full ->
            {:reply, {:error, :lobby_full}, state}

          true ->
            new_lobby = %{lobby | participants: lobby.participants ++ [participant]}
            {:reply, {:ok, new_lobby}, Map.put(state, lobby_id, new_lobby)}
        end
    end
  end

  def handle_cast({:close, lobby_id}, state) do
    {:noreply, Map.delete(state, lobby_id)}
  end

  # Таймаут — лобби протухло
  def handle_info({:expire_lobby, lobby_id}, state) do
    case Map.fetch(state, lobby_id) do
      {:ok, lobby} ->
        # Обновляем сообщение если лобби всё ещё открыто
        Nostrum.Api.Interaction.edit_response(lobby.message_token, %{
          embeds: [
            %{
              title: "⏰ Время ожидания истекло",
              description: "Лобби закрыто — не успели собрать команду.",
              color: 0x888888
            }
          ],
          components: []
        })

        {:noreply, Map.delete(state, lobby_id)}

      :error ->
        {:noreply, state}
    end
  end
end
