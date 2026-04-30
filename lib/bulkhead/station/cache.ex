defmodule Bulkhead.Station.Cache do
  @table :station_cache

  def init do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
  end

  # Station пишет в кэш при каждом изменении стейта
  def put(guild_id, state) do
    :ets.insert(@table, {guild_id, state})
  end

  # Быстрое чтение без GenServer roundtrip
  def get(guild_id) do
    case :ets.lookup(@table, guild_id) do
      [{_, state}] -> {:ok, state}
      [] -> {:error, :not_found}
    end
  end
end
