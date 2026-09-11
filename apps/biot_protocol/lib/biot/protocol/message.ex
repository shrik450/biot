defmodule Biot.Protocol.Message.Hello do
  @moduledoc "Starts protocol negotiation for one node registration."
  @enforce_keys [:registration_id, :supported_protocol_versions, :platform]
  defstruct [:registration_id, :supported_protocol_versions, :platform]

  @type t :: %__MODULE__{
          registration_id: Biot.Protocol.RegistrationId.t(),
          supported_protocol_versions: [pos_integer()],
          platform: Biot.Protocol.Platform.t()
        }

  def type, do: "hello"
end

defmodule Biot.Protocol.Message.Connected do
  @moduledoc "Confirms the connection identity and selected protocol version."
  @enforce_keys [:connection_id, :selected_protocol_version]
  defstruct [:connection_id, :selected_protocol_version]

  @type t :: %__MODULE__{
          connection_id: Biot.Protocol.ConnectionId.t(),
          selected_protocol_version: pos_integer()
        }

  def type, do: "connected"
end

defmodule Biot.Protocol.Message.Reject do
  @moduledoc "Rejects a connection during the fixed-version handshake."
  @reasons [
    :unsupported_protocol_version,
    :registration_rejected,
    :registration_retired,
    :registration_abandoned
  ]
  @type reason ::
          :unsupported_protocol_version
          | :registration_rejected
          | :registration_retired
          | :registration_abandoned

  @enforce_keys [:reason]
  defstruct [:reason]
  @type t :: %__MODULE__{reason: reason()}

  def type, do: "reject"
  def reasons, do: @reasons
end

defmodule Biot.Protocol.Message.SynchronizeBegin do
  @moduledoc "Starts one bounded server intent snapshot."
  @enforce_keys [:connection_id, :count]
  defstruct [:connection_id, :count]

  @type t :: %__MODULE__{
          connection_id: Biot.Protocol.ConnectionId.t(),
          count: non_neg_integer()
        }

  def type, do: "synchronize_begin"
end

defmodule Biot.Protocol.Message.SynchronizeItem do
  @moduledoc "Carries one item in a server intent snapshot."
  @enforce_keys [:biot_spec]
  defstruct [:biot_spec]
  @type t :: %__MODULE__{biot_spec: Biot.Protocol.BiotSpec.t()}
  def type, do: "synchronize_item"
end

defmodule Biot.Protocol.Message.SynchronizeEnd do
  @moduledoc "Ends one server intent snapshot."
  @enforce_keys [:connection_id]
  defstruct [:connection_id]
  @type t :: %__MODULE__{connection_id: Biot.Protocol.ConnectionId.t()}
  def type, do: "synchronize_end"
end

defmodule Biot.Protocol.Message.Desired do
  @moduledoc "Carries one changed biot intent."
  @enforce_keys [:biot_spec]
  defstruct [:biot_spec]
  @type t :: %__MODULE__{biot_spec: Biot.Protocol.BiotSpec.t()}
  def type, do: "desired"
end

defmodule Biot.Protocol.Message.Diagnostic do
  @moduledoc "Requests one bounded diagnostic from the node."
  @enforce_keys [:request_id, :diagnostic_id, :max_bytes, :timeout_ms]
  defstruct [:request_id, :diagnostic_id, :max_bytes, :timeout_ms]

  @type t :: %__MODULE__{
          request_id: String.t(),
          diagnostic_id: Biot.Protocol.PrivateDiagnosticId.t(),
          max_bytes: pos_integer(),
          timeout_ms: pos_integer()
        }

  def type, do: "diagnostic"
end

defmodule Biot.Protocol.Message.RuntimeLogs do
  @moduledoc "Requests bounded service-runner output from the node."
  @enforce_keys [:request_id, :biot_id, :max_bytes, :timeout_ms]
  defstruct [:request_id, :biot_id, :max_bytes, :timeout_ms]

  @type t :: %__MODULE__{
          request_id: String.t(),
          biot_id: Biot.Protocol.BiotId.t(),
          max_bytes: pos_integer(),
          timeout_ms: pos_integer()
        }

  def type, do: "runtime_logs"
end

defmodule Biot.Protocol.Message.DeliverSecret do
  @moduledoc "Delivers one runtime secret value to a biot's allocation."
  @enforce_keys [:request_id, :biot_id, :name, :value, :timeout_ms]
  defstruct [:request_id, :biot_id, :name, :value, :timeout_ms]

  @type t :: %__MODULE__{
          request_id: String.t(),
          biot_id: Biot.Protocol.BiotId.t(),
          name: Biot.Protocol.SecretName.t(),
          value: Biot.Protocol.SecretValue.t(),
          timeout_ms: pos_integer()
        }

  def type, do: "deliver_secret"
end

defmodule Biot.Protocol.Message.RemoveSecret do
  @moduledoc "Removes one runtime secret from a biot's allocation."
  @enforce_keys [:request_id, :biot_id, :name, :timeout_ms]
  defstruct [:request_id, :biot_id, :name, :timeout_ms]

  @type t :: %__MODULE__{
          request_id: String.t(),
          biot_id: Biot.Protocol.BiotId.t(),
          name: Biot.Protocol.SecretName.t(),
          timeout_ms: pos_integer()
        }

  def type, do: "remove_secret"
end

defmodule Biot.Protocol.Message.ListSecrets do
  @moduledoc "Asks which runtime secrets a biot's allocation currently holds."
  @enforce_keys [:request_id, :biot_id, :timeout_ms]
  defstruct [:request_id, :biot_id, :timeout_ms]

  @type t :: %__MODULE__{
          request_id: String.t(),
          biot_id: Biot.Protocol.BiotId.t(),
          timeout_ms: pos_integer()
        }

  def type, do: "list_secrets"
end

defmodule Biot.Protocol.Message.DeliverFetchCredential do
  @moduledoc "Delivers one source credential, scoped to one parsed HTTPS repository."
  @enforce_keys [:request_id, :biot_id, :source, :value, :timeout_ms]
  defstruct [:request_id, :biot_id, :source, :value, :timeout_ms]

  @type t :: %__MODULE__{
          request_id: String.t(),
          biot_id: Biot.Protocol.BiotId.t(),
          source: Biot.Protocol.RepositorySource.t(),
          value: Biot.Protocol.AuthorizationValue.t(),
          timeout_ms: pos_integer()
        }

  def type, do: "deliver_fetch_credential"
end

defmodule Biot.Protocol.Message.RemoveFetchCredential do
  @moduledoc "Removes the source credential a biot holds for one repository."
  @enforce_keys [:request_id, :biot_id, :source, :timeout_ms]
  defstruct [:request_id, :biot_id, :source, :timeout_ms]

  @type t :: %__MODULE__{
          request_id: String.t(),
          biot_id: Biot.Protocol.BiotId.t(),
          source: Biot.Protocol.RepositorySource.t(),
          timeout_ms: pos_integer()
        }

  def type, do: "remove_fetch_credential"
end

defmodule Biot.Protocol.Message.Synchronized do
  @moduledoc "Acknowledges the complete intent set for a connection."
  @enforce_keys [:connection_id]
  defstruct [:connection_id]
  @type t :: %__MODULE__{connection_id: Biot.Protocol.ConnectionId.t()}
  def type, do: "synchronized"
end

defmodule Biot.Protocol.Message.Observation do
  @moduledoc "Reports inspected execution state for one biot."
  @enforce_keys [:biot_id, :execution_report]
  defstruct [:biot_id, :execution_report]

  @type t :: %__MODULE__{
          biot_id: Biot.Protocol.BiotId.t(),
          execution_report: Biot.Protocol.ExecutionReport.t()
        }

  def type, do: "observation"
end

defmodule Biot.Protocol.Message.AccessApplied do
  @moduledoc "Reports the access revision applied for one biot."
  @enforce_keys [:biot_id, :access_revision]
  defstruct [:biot_id, :access_revision]

  @type t :: %__MODULE__{
          biot_id: Biot.Protocol.BiotId.t(),
          access_revision: pos_integer()
        }

  def type, do: "access_applied"
end

defmodule Biot.Protocol.Message.Resolution do
  @moduledoc "Reports the immutable manifest resolved for an environment."
  @enforce_keys [:environment_id, :manifest]
  defstruct [:environment_id, :manifest]

  @type t :: %__MODULE__{
          environment_id: Biot.Protocol.EnvironmentId.t(),
          manifest: Biot.Protocol.Manifest.t()
        }

  def type, do: "resolution"
end

defmodule Biot.Protocol.Message.NodeObservation do
  @moduledoc "Reports allocations that are absent from synchronized server intent."
  @enforce_keys [:orphaned_allocations]
  defstruct [:orphaned_allocations]
  @type t :: %__MODULE__{orphaned_allocations: [Biot.Protocol.OrphanedAllocation.t()]}
  def type, do: "node_observation"
end

defmodule Biot.Protocol.Message.DiagnosticResult do
  @moduledoc "Returns one bounded diagnostic result."
  @enforce_keys [:request_id, :result]
  defstruct [:request_id, :result]
  @type result :: {binary(), boolean()} | :not_found
  @type t :: %__MODULE__{request_id: String.t(), result: result()}
  def type, do: "diagnostic_result"
end

defmodule Biot.Protocol.Message.RuntimeLogsResult do
  @moduledoc "Returns bounded service-runner output for one container incarnation."
  @enforce_keys [:request_id, :result]
  defstruct [:request_id, :result]

  @type result :: {Biot.Protocol.IncarnationId.t(), binary(), boolean()} | :not_found
  @type t :: %__MODULE__{request_id: String.t(), result: result()}

  def type, do: "runtime_logs_result"
end

defmodule Biot.Protocol.Message.SecretResult do
  @moduledoc "Returns the outcome of one runtime secret delivery or removal."
  @enforce_keys [:request_id, :result]
  defstruct [:request_id, :result]

  @type t :: %__MODULE__{request_id: String.t(), result: Biot.Protocol.SecretOutcome.t()}

  def type, do: "secret_result"
end

defmodule Biot.Protocol.Message.SecretListResult do
  @moduledoc "Returns the runtime secret names a biot's allocation holds."
  @enforce_keys [:request_id, :result]
  defstruct [:request_id, :result]

  @type t :: %__MODULE__{request_id: String.t(), result: Biot.Protocol.SecretOutcome.listing()}

  def type, do: "secret_list_result"
end

defmodule Biot.Protocol.Message.FetchCredentialResult do
  @moduledoc "Returns the outcome of one source credential delivery or removal."
  @enforce_keys [:request_id, :result]
  defstruct [:request_id, :result]

  @type t :: %__MODULE__{request_id: String.t(), result: Biot.Protocol.SecretOutcome.t()}

  def type, do: "fetch_credential_result"
end

defmodule Biot.Protocol.Message.Heartbeat do
  @moduledoc "Challenges the peer to prove that the control connection is live."
  @enforce_keys [:challenge]
  defstruct [:challenge]
  @type t :: %__MODULE__{challenge: String.t()}
  def type, do: "heartbeat"
end

defmodule Biot.Protocol.Message.HeartbeatResponse do
  @moduledoc "Answers one peer heartbeat challenge."
  @enforce_keys [:challenge]
  defstruct [:challenge]
  @type t :: %__MODULE__{challenge: String.t()}
  def type, do: "heartbeat_response"
end
