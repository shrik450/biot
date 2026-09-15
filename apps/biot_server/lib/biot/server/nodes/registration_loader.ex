defmodule Biot.Server.Nodes.RegistrationLoader do
  @moduledoc "Loads the operator's node enrollment file without changing database state."

  alias Biot.Server.Nodes.Registration
  alias Biot.Server.OperatorFile

  @type error :: OperatorFile.error({atom(), atom()})

  @spec load() :: {:ok, [Registration.t()]} | {:error, error()}
  def load do
    :biot_server
    |> Application.get_env(:node_registrations_file)
    |> OperatorFile.load(&Registration.parse/1)
  end

  @spec message(error()) :: String.t()
  def message(error), do: OperatorFile.message("node registrations", error)
end
