defmodule Biot.Server.Principals.Startup do
  @moduledoc false

  alias Biot.Server.Principals

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
    case Principals.reload() do
      :ok -> :ignore
      {:error, rejection} -> failed(Principals.message(rejection))
    end
  end

  defp failed(message), do: {:error, "principal configuration failed: #{message}"}
end
