defmodule Biot.Server.Repo do
  use Ecto.Repo,
    otp_app: :biot_server,
    adapter: Ecto.Adapters.SQLite3
end
