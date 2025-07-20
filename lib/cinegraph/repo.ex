defmodule Cinegraph.Repo do
  use Ecto.Repo,
    otp_app: :cinegraph,
    adapter: Ecto.Adapters.Postgres
end
