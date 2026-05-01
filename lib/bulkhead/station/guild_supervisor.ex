defmodule Bulkhead.Station.GuildSupervisor do
  use Supervisor

  def start_link(args) do
    guild_id = Keyword.fetch!(args, :guild_id)

    name = {:via, Registry, {Bulkhead.Registry, {:guild_sup, guild_id}}}
    Supervisor.start_link(__MODULE__, args, name: name)
  end

  def init(args) do
    guild_id = args[:guild_id]

    children = [
      {Bulkhead.Hangar, guild_id: guild_id},
      {Bulkhead.Station, guild_id: guild_id},
      {DynamicSupervisor, strategy: :one_for_one, name: mission_sup_name(guild_id)}
    ]

    # :rest_for_one
    # Я так понял в порядке возрастания, если упадет Hangar то перезапустит все нижние
    # Если Mission то тока его
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp mission_sup_name(guild_id),
    do: {:via, Registry, {Bulkhead.Registry, {:mission_sup, guild_id}}}
end
