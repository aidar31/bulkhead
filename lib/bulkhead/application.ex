defmodule Bulkhead.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    bot_opts = %{
      name: BulkheadBot,
      consumer: BulkheadBot.Consumer,
      intents: [:guilds, :guild_messages, :message_content],
      wrapped_token: fn -> Application.get_env(:bulkhead, :bot_token) end
    }

    children = [
      BulkheadWeb.Telemetry,
      Bulkhead.Repo,
      {DNSCluster, query: Application.get_env(:bulkhead, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Bulkhead.PubSub},
      BulkheadWeb.Endpoint,
      {Nostrum.Bot, bot_opts}
    ]

    opts = [strategy: :one_for_one, name: Bulkhead.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BulkheadWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
