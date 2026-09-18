defmodule BiotWeb.Components.BiotSummary do
  @moduledoc "Chooses the concise Biot list summary in server-defined priority order."

  use BiotWeb, :html

  alias Biot.Server.Queries.BiotView
  alias Biot.Server.Queries.OperationView
  alias BiotWeb.BiotState
  alias BiotWeb.Components.Operation
  alias BiotWeb.Components.Status

  attr :biot, :any, required: true

  @spec summary(map()) :: Phoenix.LiveView.Rendered.t()
  def summary(assigns) do
    value = value(assigns.biot)

    assigns = assign(assigns, :summary, value)

    ~H"""
    <div class={"biot-summary summary-#{@summary.tone}"}>
      <strong>{@summary.label}</strong>
      <span :if={@summary.detail} class="muted">{@summary.detail}</span>
    </div>
    """
  end

  @spec value(BiotView.t()) :: %{label: String.t(), detail: String.t() | nil, tone: String.t()}
  def value(%BiotView{} = view) do
    case BiotState.current_failure(view) do
      nil -> value_without_failure(view)
      failure -> %{label: "failure", detail: failure.message, tone: "failure"}
    end
  end

  defp value_without_failure(%BiotView{actual: %{waiting_for: {:fetch_credential, source}}}) do
    %{label: "waiting for credential", detail: source.url, tone: "waiting"}
  end

  defp value_without_failure(%BiotView{operation: %OperationView{outcome: outcome}})
       when outcome in [:pending, :working] do
    %{
      label: "operation #{Operation.outcome(outcome)}",
      detail: nil,
      tone: "working"
    }
  end

  defp value_without_failure(%BiotView{node: node})
       when node in [:unavailable, :disabled, :retired, :abandoned] do
    %{label: "node #{Status.label(node)}", detail: nil, tone: "attention"}
  end

  defp value_without_failure(%BiotView{actual: %{container: {:present, _incarnation, :running}}}) do
    %{label: "observed running", detail: nil, tone: "healthy"}
  end

  defp value_without_failure(%BiotView{actual: %{container: {:present, _incarnation, :starting}}}) do
    %{label: "observed starting", detail: nil, tone: "working"}
  end

  defp value_without_failure(%BiotView{
         actual: %{container: {:present, _incarnation, {:exited, status}}}
       }) do
    %{label: "observed exited", detail: "status #{status}", tone: "attention"}
  end

  defp value_without_failure(%BiotView{actual: %{container: :absent}}) do
    %{label: "observed absent", detail: nil, tone: "muted"}
  end

  defp value_without_failure(%BiotView{actual: %{container: :unknown}}) do
    %{label: "observation unknown", detail: nil, tone: "muted"}
  end

  defp value_without_failure(%BiotView{actual: :never_reported, desired: %{state: state}}) do
    %{label: "desired #{state}", detail: "never observed", tone: "muted"}
  end

  defp value_without_failure(%BiotView{desired: %{state: state}}) do
    %{label: "desired #{state}", detail: nil, tone: "muted"}
  end
end
