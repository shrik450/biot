defmodule BiotWeb.Live.NewBiotWorkflow do
  @moduledoc "Pure state transitions for credentialed Biot creation."

  alias Biot.Protocol.BiotId
  alias Biot.Server.Queries.BiotView
  alias BiotWeb.BiotState
  alias BiotWeb.Live.NewBiotForm

  @enforce_keys [:biot_id, :phase, :final_state, :runtime_secrets, :source_credentials]
  defstruct biot_id: nil,
            phase: :allocation,
            final_state: :running,
            status: :active,
            reason: nil,
            runtime_secrets: [],
            source_credentials: []

  @type phase ::
          :allocation
          | :preparation
          | :starting
          | :start
          | :source_credentials
          | :runtime_secrets
  @type status :: :active | :failed
  @type final_state :: :running | :stopped
  @type t :: %__MODULE__{
          biot_id: BiotId.t(),
          phase: phase(),
          final_state: final_state(),
          status: status(),
          reason: term() | nil,
          runtime_secrets: [NewBiotForm.runtime_secret()],
          source_credentials: [NewBiotForm.source_credential()]
        }

  @type decision ::
          {:wait, t()}
          | {:deliver_sources, t()}
          | {:deliver_runtime_secrets, t()}
          | {:start, t()}
          | {:finish, t()}
          | {:failed, t()}

  @spec new(
          BiotId.t(),
          final_state(),
          [NewBiotForm.runtime_secret()],
          [NewBiotForm.source_credential()]
        ) :: t()
  def new(%BiotId{} = biot_id, final_state, runtime_secrets, source_credentials)
      when final_state in [:running, :stopped] do
    %__MODULE__{
      biot_id: biot_id,
      phase: :allocation,
      final_state: final_state,
      runtime_secrets: runtime_secrets,
      source_credentials: source_credentials
    }
  end

  @spec advance(t(), BiotView.t()) :: decision()
  def advance(%__MODULE__{phase: :allocation} = workflow, view) do
    decide(workflow, view, :allocation, allocation_ready?(view), :deliver_sources)
  end

  def advance(%__MODULE__{phase: :preparation} = workflow, view) do
    decide(workflow, view, :preparation, preparation_ready?(view), :deliver_runtime_secrets)
  end

  def advance(%__MODULE__{phase: :starting} = workflow, view) do
    case BiotState.current_failure(view) do
      nil ->
        if workflow.final_state == :running, do: {:start, workflow}, else: {:finish, workflow}

      failure ->
        {:failed, failed(workflow, :starting, failure)}
    end
  end

  @spec sources_delivered(t()) :: t()
  def sources_delivered(%__MODULE__{} = workflow) do
    %{workflow | phase: :preparation, source_credentials: []}
  end

  @spec runtime_secrets_delivered(t()) :: t()
  def runtime_secrets_delivered(%__MODULE__{} = workflow) do
    %{workflow | phase: :starting, runtime_secrets: []}
  end

  @spec failed(t(), phase(), term()) :: t()
  def failed(%__MODULE__{} = workflow, phase, reason) do
    %{
      workflow
      | phase: phase,
        status: :failed,
        reason: reason,
        runtime_secrets: [],
        source_credentials: []
    }
  end

  defp decide(workflow, view, phase, ready?, action) do
    case {BiotState.current_failure(view), ready?} do
      {nil, true} -> {action, workflow}
      {nil, false} -> {:wait, workflow}
      {failure, _ready} -> {:failed, failed(workflow, phase, failure)}
    end
  end

  defp allocation_ready?(%{actual: %{data: data}}) when data in [:uninitialized, :present],
    do: true

  defp allocation_ready?(_view), do: false

  defp preparation_ready?(%{
         actual: %{installed_environment: installed},
         desired: %{environment_id: desired}
       }),
       do: installed == desired

  defp preparation_ready?(_view), do: false
end
