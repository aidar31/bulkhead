defmodule Bulkhead.Repo do
  use Ecto.Repo,
    otp_app: :bulkhead,
    adapter: Ecto.Adapters.Postgres
end
