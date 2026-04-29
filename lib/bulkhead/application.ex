defmodule Bulkhead.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BulkheadWeb.Telemetry,
      Bulkhead.Repo,
      {DNSCluster, query: Application.get_env(:bulkhead, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Bulkhead.PubSub},
      BulkheadWeb.Endpoint
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
