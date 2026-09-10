defmodule Biot.Node.Host.Outcome do
  @moduledoc "An expected host outcome with its retry reason and bounded diagnostic."

  alias Biot.Node.Diagnostic
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Diagnostic, as: HostDiagnostic
  alias Biot.Node.InspectionFailure
  alias Biot.Node.Retry

  @enforce_keys [:outcome, :diagnostic]
  defstruct [:outcome, :diagnostic]

  @type t :: %__MODULE__{
          outcome: Retry.reason(),
          diagnostic: Diagnostic.t() | nil
        }

  @spec new(Retry.reason(), Diagnostic.t() | nil) :: t()
  def new(outcome, diagnostic \\ nil), do: %__MODULE__{outcome: outcome, diagnostic: diagnostic}

  @spec from_reason(term(), Diagnostic.t() | nil) :: t()
  def from_reason(%__MODULE__{} = outcome, _diagnostic), do: outcome

  def from_reason(%InspectionFailure{detail: detail}, diagnostic),
    do: new(:host_unavailable, diagnostic || detail)

  def from_reason(:enospc, diagnostic),
    do: new(:host_unavailable, diagnostic || Diagnostic.text("the disk is full"))

  def from_reason(reason, diagnostic) do
    new(:host_unavailable, diagnostic || Diagnostic.text(describe(reason)))
  end

  @spec from_reason(term()) :: t()
  def from_reason(reason), do: from_reason(reason, nil)

  @spec from_command(Retry.reason(), Command.Result.t()) :: t()
  def from_command(reason, %Command.Result{} = result),
    do: new(reason, HostDiagnostic.from_command(result))

  @spec inspection(InspectionFailure.resource(), term(), Diagnostic.t()) :: InspectionFailure.t()
  def inspection(resource, reason, detail) do
    %InspectionFailure{resource: resource, reason: inspection_reason(reason), detail: detail}
  end

  defp inspection_reason(:eacces), do: :denied
  defp inspection_reason(:eperm), do: :denied
  defp inspection_reason(:timed_out), do: :timed_out
  defp inspection_reason(:unreadable), do: :unreadable
  defp inspection_reason(_reason), do: :unavailable

  defp describe(reason) do
    reason
    |> inspect(limit: 8, printable_limit: 240)
    |> String.slice(0, 240)
  end
end
