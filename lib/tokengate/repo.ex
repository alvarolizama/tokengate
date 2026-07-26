defmodule Tokengate.Repo do
  use Ecto.Repo,
    otp_app: :tokengate,
    adapter: Ecto.Adapters.Postgres
end
