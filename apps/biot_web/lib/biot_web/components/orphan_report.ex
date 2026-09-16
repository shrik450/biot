defmodule BiotWeb.Components.OrphanReport do
  @moduledoc "Renders the node's latest truthful orphan report."

  use BiotWeb, :html

  alias Biot.Protocol.OrphanedAllocation

  attr :report, :any, required: true
  attr :node_id, :any, required: true

  @spec orphan_report(map()) :: Phoenix.LiveView.Rendered.t()
  def orphan_report(assigns) do
    ~H"""
    <span :if={@report == :never_reported} class="muted">never reported</span>
    <span :if={@report != :never_reported and @report.allocations == []}>
      none · <.timestamp value={@report.reported_at} node_id={@node_id} />
    </span>
    <details :if={@report != :never_reported and @report.allocations != []} class="orphan-details">
      <summary>{length(@report.allocations)} reported</summary>
      <ul class="compact-list">
        <li :for={allocation <- @report.allocations}>
          <span class="breakable">{to_string(allocation.biot_id)}</span>
          <span class="muted">uid {uid_range(allocation)}</span>
        </li>
      </ul>
      <.timestamp value={@report.reported_at} node_id={@node_id} />
    </details>
    """
  end

  attr :value, :any, required: true
  attr :node_id, :any, required: true

  defp timestamp(assigns) do
    ~H"""
    <time
      id={"orphan-reported-at-#{to_string(@node_id)}"}
      datetime={DateTime.to_iso8601(@value)}
      title={DateTime.to_iso8601(@value)}
      phx-hook="LocalizedTime"
    >
      {DateTime.to_iso8601(@value)}
    </time>
    """
  end

  @spec uid_range(OrphanedAllocation.t()) :: String.t()
  def uid_range(%OrphanedAllocation{uid_range: %{start: start, count: count}}),
    do: "#{start} + #{count}"
end
