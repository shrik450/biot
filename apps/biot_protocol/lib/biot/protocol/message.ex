defmodule Biot.Protocol.Message do
  @moduledoc """
  Declares the control and stream messages: each one's wire type and, for every field, the codec
  `Biot.Protocol.Wire` carries it with. A field is declared once, here, and `Wire` encodes,
  decodes, and bounds every message from these declarations.

  Codecs:

    * `{:text, module}`: a parsed value whose canonical form is a string, through
      `module.parse/1` and `module.to_string/1`
    * `{:json, module}`: a composite value, through `module.parse/1` and `module.encode/1`
    * `{:list, module}`: a list of composite values
    * `{:choice, atoms}`: one of a closed set of atoms, written as its name
    * `:text`: non-empty text, such as a request ID or a heartbeat challenge
    * `:positive_integer`, `:non_negative_integer`, and `:protocol_versions`
    * `:biot_spec`: a `BiotSpec` within the version's size bound
    * `:secret_value` and `:authorization_value`: a redacted value within the version's bound,
      base64 on the wire
    * `:secret_listing`, `:diagnostic_result`, and `:runtime_logs_result`: result unions
  """

  @type codec ::
          {:text | :json | :list, module()}
          | {:choice, [atom()]}
          | :text
          | :positive_integer
          | :non_negative_integer
          | :protocol_versions
          | :biot_spec
          | :secret_value
          | :authorization_value
          | :secret_listing
          | :diagnostic_result
          | :runtime_logs_result

  @callback type() :: String.t()
  @callback fields() :: [{atom(), codec()}]

  defmacro __using__(options) do
    type = Keyword.fetch!(options, :type)
    fields = Keyword.get(options, :fields, [])

    quote do
      @behaviour Biot.Protocol.Message

      @enforce_keys Keyword.keys(unquote(fields))
      defstruct Keyword.keys(unquote(fields))

      @impl Biot.Protocol.Message
      def type, do: unquote(type)

      @impl Biot.Protocol.Message
      def fields, do: unquote(fields)
    end
  end
end

defmodule Biot.Protocol.Message.Hello do
  @moduledoc "Starts protocol negotiation for one node registration."

  alias Biot.Protocol.Platform
  alias Biot.Protocol.RegistrationId

  use Biot.Protocol.Message,
    type: "hello",
    fields: [
      registration_id: {:text, RegistrationId},
      supported_protocol_versions: :protocol_versions,
      platform: {:text, Platform}
    ]

  @type t :: %__MODULE__{
          registration_id: RegistrationId.t(),
          supported_protocol_versions: [pos_integer()],
          platform: Platform.t()
        }
end

defmodule Biot.Protocol.Message.Connected do
  @moduledoc "Confirms the connection identity and selected protocol version."

  alias Biot.Protocol.ConnectionId

  use Biot.Protocol.Message,
    type: "connected",
    fields: [connection_id: {:text, ConnectionId}, selected_protocol_version: :positive_integer]

  @type t :: %__MODULE__{
          connection_id: ConnectionId.t(),
          selected_protocol_version: pos_integer()
        }
end

defmodule Biot.Protocol.Message.Reject do
  @moduledoc "Rejects a connection during the fixed-version handshake."

  @reasons [
    :unsupported_protocol_version,
    :registration_rejected,
    :registration_retired,
    :registration_abandoned,
    :unknown_stream
  ]

  use Biot.Protocol.Message, type: "reject", fields: [reason: {:choice, @reasons}]

  @type reason ::
          :unsupported_protocol_version
          | :registration_rejected
          | :registration_retired
          | :registration_abandoned
          | :unknown_stream

  @type t :: %__MODULE__{reason: reason()}

  @spec reasons() :: [reason()]
  def reasons, do: @reasons
end

defmodule Biot.Protocol.Message.Attach do
  @moduledoc "Binds one new stream connection to a stream waiting on a control connection."

  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.StreamId

  use Biot.Protocol.Message,
    type: "attach",
    fields: [
      registration_id: {:text, RegistrationId},
      connection_id: {:text, ConnectionId},
      stream_id: {:text, StreamId}
    ]

  @type t :: %__MODULE__{
          registration_id: RegistrationId.t(),
          connection_id: ConnectionId.t(),
          stream_id: StreamId.t()
        }
end

defmodule Biot.Protocol.Message.Attached do
  @moduledoc "Confirms that a stream connection is bound to its stream."

  use Biot.Protocol.Message, type: "attached"

  @type t :: %__MODULE__{}
end

defmodule Biot.Protocol.Message.SynchronizeBegin do
  @moduledoc "Starts one bounded server intent snapshot."

  alias Biot.Protocol.ConnectionId

  use Biot.Protocol.Message,
    type: "synchronize_begin",
    fields: [connection_id: {:text, ConnectionId}, count: :non_negative_integer]

  @type t :: %__MODULE__{connection_id: ConnectionId.t(), count: non_neg_integer()}
end

defmodule Biot.Protocol.Message.SynchronizeItem do
  @moduledoc "Carries one item in a server intent snapshot."

  use Biot.Protocol.Message, type: "synchronize_item", fields: [biot_spec: :biot_spec]

  @type t :: %__MODULE__{biot_spec: Biot.Protocol.BiotSpec.t()}
end

defmodule Biot.Protocol.Message.SynchronizeEnd do
  @moduledoc "Ends one server intent snapshot."

  alias Biot.Protocol.ConnectionId

  use Biot.Protocol.Message,
    type: "synchronize_end",
    fields: [connection_id: {:text, ConnectionId}]

  @type t :: %__MODULE__{connection_id: ConnectionId.t()}
end

defmodule Biot.Protocol.Message.Desired do
  @moduledoc "Carries one changed biot intent."

  use Biot.Protocol.Message, type: "desired", fields: [biot_spec: :biot_spec]

  @type t :: %__MODULE__{biot_spec: Biot.Protocol.BiotSpec.t()}
end

defmodule Biot.Protocol.Message.Diagnostic do
  @moduledoc "Requests one bounded diagnostic from the node."

  alias Biot.Protocol.PrivateDiagnosticId

  use Biot.Protocol.Message,
    type: "diagnostic",
    fields: [
      request_id: :text,
      diagnostic_id: {:text, PrivateDiagnosticId},
      max_bytes: :positive_integer,
      timeout_ms: :positive_integer
    ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          diagnostic_id: PrivateDiagnosticId.t(),
          max_bytes: pos_integer(),
          timeout_ms: pos_integer()
        }
end

defmodule Biot.Protocol.Message.RuntimeLogs do
  @moduledoc "Requests bounded service-runner output from the node."

  alias Biot.Protocol.BiotId

  use Biot.Protocol.Message,
    type: "runtime_logs",
    fields: [
      request_id: :text,
      biot_id: {:text, BiotId},
      max_bytes: :positive_integer,
      timeout_ms: :positive_integer
    ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          biot_id: BiotId.t(),
          max_bytes: pos_integer(),
          timeout_ms: pos_integer()
        }
end

defmodule Biot.Protocol.Message.DeliverSecret do
  @moduledoc "Delivers one runtime secret value to a biot's allocation."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.SecretName
  alias Biot.Protocol.SecretValue

  use Biot.Protocol.Message,
    type: "deliver_secret",
    fields: [
      request_id: :text,
      biot_id: {:text, BiotId},
      name: {:text, SecretName},
      value: :secret_value,
      timeout_ms: :positive_integer
    ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          biot_id: BiotId.t(),
          name: SecretName.t(),
          value: SecretValue.t(),
          timeout_ms: pos_integer()
        }
end

defmodule Biot.Protocol.Message.RemoveSecret do
  @moduledoc "Removes one runtime secret from a biot's allocation."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.SecretName

  use Biot.Protocol.Message,
    type: "remove_secret",
    fields: [
      request_id: :text,
      biot_id: {:text, BiotId},
      name: {:text, SecretName},
      timeout_ms: :positive_integer
    ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          biot_id: BiotId.t(),
          name: SecretName.t(),
          timeout_ms: pos_integer()
        }
end

defmodule Biot.Protocol.Message.ListSecrets do
  @moduledoc "Asks which runtime secrets a biot's allocation currently holds."

  alias Biot.Protocol.BiotId

  use Biot.Protocol.Message,
    type: "list_secrets",
    fields: [request_id: :text, biot_id: {:text, BiotId}, timeout_ms: :positive_integer]

  @type t :: %__MODULE__{request_id: String.t(), biot_id: BiotId.t(), timeout_ms: pos_integer()}
end

defmodule Biot.Protocol.Message.DeliverFetchCredential do
  @moduledoc "Delivers one source credential, scoped to one parsed HTTPS repository."

  alias Biot.Protocol.AuthorizationValue
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.RepositorySource

  use Biot.Protocol.Message,
    type: "deliver_fetch_credential",
    fields: [
      request_id: :text,
      biot_id: {:text, BiotId},
      source: {:text, RepositorySource},
      value: :authorization_value,
      timeout_ms: :positive_integer
    ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          biot_id: BiotId.t(),
          source: RepositorySource.t(),
          value: AuthorizationValue.t(),
          timeout_ms: pos_integer()
        }
end

defmodule Biot.Protocol.Message.RemoveFetchCredential do
  @moduledoc "Removes the source credential a biot holds for one repository."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.RepositorySource

  use Biot.Protocol.Message,
    type: "remove_fetch_credential",
    fields: [
      request_id: :text,
      biot_id: {:text, BiotId},
      source: {:text, RepositorySource},
      timeout_ms: :positive_integer
    ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          biot_id: BiotId.t(),
          source: RepositorySource.t(),
          timeout_ms: pos_integer()
        }
end

defmodule Biot.Protocol.Message.OpenStream do
  @moduledoc "Asks a node to admit one stream under an access revision."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.StreamId
  alias Biot.Protocol.StreamTarget

  use Biot.Protocol.Message,
    type: "open_stream",
    fields: [
      connection_id: {:text, ConnectionId},
      access_revision: :positive_integer,
      stream_id: {:text, StreamId},
      biot_id: {:text, BiotId},
      target: {:json, StreamTarget}
    ]

  @type t :: %__MODULE__{
          connection_id: ConnectionId.t(),
          access_revision: pos_integer(),
          stream_id: StreamId.t(),
          biot_id: BiotId.t(),
          target: StreamTarget.t()
        }
end

defmodule Biot.Protocol.Message.StreamFailed do
  @moduledoc "Reports that one requested stream could not be opened or was ended."

  alias Biot.Protocol.StreamFailure
  alias Biot.Protocol.StreamId

  use Biot.Protocol.Message,
    type: "stream_failed",
    fields: [stream_id: {:text, StreamId}, reason: {:text, StreamFailure}]

  @type t :: %__MODULE__{stream_id: StreamId.t(), reason: StreamFailure.t()}
end

defmodule Biot.Protocol.Message.Synchronized do
  @moduledoc "Acknowledges the complete intent set for a connection."

  alias Biot.Protocol.ConnectionId

  use Biot.Protocol.Message, type: "synchronized", fields: [connection_id: {:text, ConnectionId}]

  @type t :: %__MODULE__{connection_id: ConnectionId.t()}
end

defmodule Biot.Protocol.Message.Observation do
  @moduledoc "Reports inspected execution state for one biot."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ExecutionReport

  use Biot.Protocol.Message,
    type: "observation",
    fields: [biot_id: {:text, BiotId}, execution_report: {:json, ExecutionReport}]

  @type t :: %__MODULE__{biot_id: BiotId.t(), execution_report: ExecutionReport.t()}
end

defmodule Biot.Protocol.Message.AccessApplied do
  @moduledoc "Reports the access revision applied for one biot."

  alias Biot.Protocol.BiotId

  use Biot.Protocol.Message,
    type: "access_applied",
    fields: [biot_id: {:text, BiotId}, access_revision: :positive_integer]

  @type t :: %__MODULE__{biot_id: BiotId.t(), access_revision: pos_integer()}
end

defmodule Biot.Protocol.Message.Resolution do
  @moduledoc "Reports the immutable manifest resolved for an environment."

  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.Manifest

  use Biot.Protocol.Message,
    type: "resolution",
    fields: [environment_id: {:text, EnvironmentId}, manifest: {:json, Manifest}]

  @type t :: %__MODULE__{environment_id: EnvironmentId.t(), manifest: Manifest.t()}
end

defmodule Biot.Protocol.Message.NodeObservation do
  @moduledoc "Reports allocations that are absent from synchronized server intent."

  alias Biot.Protocol.OrphanedAllocation

  use Biot.Protocol.Message,
    type: "node_observation",
    fields: [orphaned_allocations: {:list, OrphanedAllocation}]

  @type t :: %__MODULE__{orphaned_allocations: [OrphanedAllocation.t()]}
end

defmodule Biot.Protocol.Message.DiagnosticResult do
  @moduledoc "Returns one bounded diagnostic result."

  use Biot.Protocol.Message,
    type: "diagnostic_result",
    fields: [request_id: :text, result: :diagnostic_result]

  @type result :: {binary(), boolean()} | :not_found
  @type t :: %__MODULE__{request_id: String.t(), result: result()}
end

defmodule Biot.Protocol.Message.RuntimeLogsResult do
  @moduledoc "Returns bounded service-runner output for one container incarnation."

  use Biot.Protocol.Message,
    type: "runtime_logs_result",
    fields: [request_id: :text, result: :runtime_logs_result]

  @type result :: {Biot.Protocol.IncarnationId.t(), binary(), boolean()} | :not_found
  @type t :: %__MODULE__{request_id: String.t(), result: result()}
end

defmodule Biot.Protocol.Message.SecretResult do
  @moduledoc "Returns the outcome of one runtime secret delivery or removal."

  alias Biot.Protocol.SecretOutcome

  use Biot.Protocol.Message,
    type: "secret_result",
    fields: [request_id: :text, result: {:json, SecretOutcome}]

  @type t :: %__MODULE__{request_id: String.t(), result: SecretOutcome.t()}
end

defmodule Biot.Protocol.Message.SecretListResult do
  @moduledoc "Returns the runtime secret names a biot's allocation holds."

  use Biot.Protocol.Message,
    type: "secret_list_result",
    fields: [request_id: :text, result: :secret_listing]

  @type t :: %__MODULE__{request_id: String.t(), result: Biot.Protocol.SecretOutcome.listing()}
end

defmodule Biot.Protocol.Message.FetchCredentialResult do
  @moduledoc "Returns the outcome of one source credential delivery or removal."

  alias Biot.Protocol.SecretOutcome

  use Biot.Protocol.Message,
    type: "fetch_credential_result",
    fields: [request_id: :text, result: {:json, SecretOutcome}]

  @type t :: %__MODULE__{request_id: String.t(), result: SecretOutcome.t()}
end

defmodule Biot.Protocol.Message.Heartbeat do
  @moduledoc "Challenges the peer to prove that the control connection is live."

  use Biot.Protocol.Message, type: "heartbeat", fields: [challenge: :text]

  @type t :: %__MODULE__{challenge: String.t()}
end

defmodule Biot.Protocol.Message.HeartbeatResponse do
  @moduledoc "Answers one peer heartbeat challenge."

  use Biot.Protocol.Message, type: "heartbeat_response", fields: [challenge: :text]

  @type t :: %__MODULE__{challenge: String.t()}
end
