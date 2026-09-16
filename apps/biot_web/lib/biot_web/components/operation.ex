defmodule BiotWeb.Components.Operation do
  @moduledoc "Formats lifecycle operations and their outcomes for list pages."

  use BiotWeb, :html

  alias Biot.Server.Queries.OperationView

  attr :operation, :any, required: true

  @spec operation(map()) :: Phoenix.LiveView.Rendered.t()
  def operation(assigns) do
    ~H"""
    <span :if={is_nil(@operation)} class="muted">none</span>
    <span :if={@operation} class="operation-detail">
      <span class="operation-kind">{kind(@operation.kind)}</span>
      <span class={"operation-outcome outcome-#{outcome_class(@operation.outcome)}"}>
        {outcome(@operation.outcome)}
      </span>
      <span class="muted">revision {@operation.target_revision}</span>
    </span>
    """
  end

  @spec kind(atom()) :: String.t()
  def kind(:update_environment), do: "update environment"
  def kind(:create), do: "create"
  def kind(:start), do: "start"
  def kind(:stop), do: "stop"
  def kind(:destroy), do: "destroy"

  @spec outcome(OperationView.outcome()) :: String.t()
  def outcome(:pending), do: "pending"
  def outcome(:working), do: "working"
  def outcome(:succeeded), do: "succeeded"
  def outcome(:superseded), do: "superseded"
  def outcome({:failed, failure}), do: "failed: #{failure.code}"

  @spec outcome_class(OperationView.outcome()) :: String.t()
  def outcome_class(value) when value in [:pending, :working], do: "pending"
  def outcome_class(:succeeded), do: "succeeded"
  def outcome_class(:superseded), do: "superseded"
  def outcome_class({:failed, _failure}), do: "failed"
end
