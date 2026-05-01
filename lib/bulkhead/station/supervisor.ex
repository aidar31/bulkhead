defmodule Bulkhead.Station.Supervisor do
  use DynamicSupervisor

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_station(guild_id) do
    spec = {Bulkhead.Station.GuildSupervisor, guild_id: guild_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def start_guild_services(guild_id) do
    spec = {Bulkhead.Station.GuildSupervisor, guild_id: guild_id}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stop_station(guild_id) do
    case Bulkhead.Station.whereis(guild_id) do
      {pid, _} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      nil -> :ok
    end
  end
end
