defmodule Biot.Node.Repo do
  @moduledoc "The SQLite repository for node-local ownership records."

  use Ecto.Repo,
    otp_app: :biot_node,
    adapter: Ecto.Adapters.SQLite3

  alias Biot.Node.Host.Paths

  @impl true
  def init(_context, config) do
    root = Application.fetch_env!(:biot_node, :data_root)
    {:ok, Keyword.put(config, :database, Paths.journal(root))}
  end
end
