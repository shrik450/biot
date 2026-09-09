defmodule Biot.Server.Nodes.Startup do
  @moduledoc false

  alias Biot.Server.Nodes
  alias Biot.Server.Nodes.RegistrationLoader

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: :ignore | {:error, String.t()}
  def start_link(_opts) do
    case RegistrationLoader.load() do
      {:ok, registrations} -> enroll(registrations)
      {:error, error} -> failed(RegistrationLoader.message(error))
    end
  end

  defp enroll(registrations) do
    case Nodes.enroll(registrations) do
      {:ok, _nodes} -> :ignore
      {:error, rejection} -> failed(Nodes.message(rejection))
    end
  end

  defp failed(message), do: {:error, "node enrollment failed: #{message}"}
end
