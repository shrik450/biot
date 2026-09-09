defmodule Biot.Server.DataCase do
  @moduledoc "Checks out an isolated server database connection for integration tests."

  use ExUnit.CaseTemplate

  alias Biot.Server.Repo
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Biot.Server.Repo
    end
  end

  setup tags do
    owner = Sandbox.start_owner!(Repo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end
end
