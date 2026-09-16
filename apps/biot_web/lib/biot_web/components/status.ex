defmodule BiotWeb.Components.Status do
  @moduledoc "Renders the finite status vocabulary used by list pages."

  use BiotWeb, :html

  attr :value, :any, required: true

  @spec status(map()) :: Phoenix.LiveView.Rendered.t()
  def status(assigns) do
    ~H"""
    <span class={"status status-#{class(@value)}"}>
      <span class="status-dot" aria-hidden="true"></span>
      <span>{label(@value)}</span>
    </span>
    """
  end

  @spec label(atom()) :: String.t()
  def label(:enabled), do: "enabled"
  def label(:disabled), do: "disabled"
  def label(:retired), do: "retired"
  def label(:abandoned), do: "abandoned"
  def label(:connecting), do: "connecting"
  def label(:ready), do: "ready"
  def label(:unavailable), do: "unavailable"
  def label(:never_reported), do: "never reported"

  @spec class(atom()) :: String.t()
  def class(value) when value in [:enabled, :ready], do: "healthy"
  def class(value) when value in [:connecting], do: "pending"
  def class(value) when value in [:disabled, :retired, :abandoned, :unavailable], do: "attention"
  def class(:never_reported), do: "unknown"
end
