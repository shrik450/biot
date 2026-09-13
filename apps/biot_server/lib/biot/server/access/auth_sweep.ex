defmodule Biot.Server.Access.AuthSweep do
  @moduledoc """
  Calls `Access.Admission.close_invalid_proof_owners/0` every `auth_check_interval_ms`.

  A logout, revocation, or principal disable closes its owners itself, but that close can be lost.
  This check bounds how long such an owner stays open. It is separate from each browser owner's
  absolute expiry timer. A nil interval disables the process.
  """

  use GenServer

  alias Biot.Server.Access.Admission

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(_options) do
    case Application.get_env(:biot_server, :auth_check_interval_ms) do
      nil -> :ignore
      interval_ms -> GenServer.start_link(__MODULE__, interval_ms)
    end
  end

  @impl true
  def init(interval_ms) do
    schedule(interval_ms)
    {:ok, interval_ms}
  end

  @impl true
  def handle_info(:check, interval_ms) do
    :ok = Admission.close_invalid_proof_owners()
    schedule(interval_ms)
    {:noreply, interval_ms}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :check, interval_ms)
end
