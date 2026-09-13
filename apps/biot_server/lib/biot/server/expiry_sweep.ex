defmodule Biot.Server.ExpirySweep do
  @moduledoc """
  Deletes expired sessions, preview handoffs, and credentials.

  One clock reading per run feeds every owner's delete query, so a run uses one
  consistent time. A nil interval disables the process.
  """

  use GenServer

  alias Biot.Server.{Credentials, PreviewHandoff, Sessions}

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(_options) do
    case interval_ms() do
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
  def handle_info(:sweep, interval_ms) do
    now = DateTime.utc_now()

    Sessions.sweep_expired(now)
    PreviewHandoff.sweep_expired(now)
    Credentials.sweep_expired(now)

    schedule(interval_ms)
    {:noreply, interval_ms}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)

  defp interval_ms, do: Application.get_env(:biot_server, :expiry_sweep_interval_ms)
end
