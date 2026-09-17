defmodule BiotWeb.Params do
  @moduledoc """
  Parses request parameters into the values that application functions take.

  Each function takes the path, body, or query parameters as separate maps, so a body field can
  never replace a path ID. It returns every parsed value, or `invalid_input` with a reason for each
  bad field. A missing required field is `missing`. An optional field that is absent or `null`
  takes its default. Fields that a function does not name are ignored.
  """

  alias Biot.Protocol.AuthorizationValue
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotName
  alias Biot.Protocol.CredentialId
  alias Biot.Protocol.Digest
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.Hostname
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.OperationId
  alias Biot.Protocol.Port
  alias Biot.Protocol.PrincipalId
  alias Biot.Protocol.PrivateDiagnosticId
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SameOriginPath
  alias Biot.Protocol.SecretName
  alias Biot.Protocol.SecretValue
  alias Biot.Protocol.SshKeyId
  alias Biot.Protocol.Version
  alias Biot.Server.Biots.Create
  alias Biot.Server.Biots.SelectEnvironment
  alias Biot.Server.CommandError
  alias Biot.Server.Queries.Biots

  @default_page_limit 50
  @max_page_limit 200

  @type params :: %{optional(String.t()) => term()}
  @type result(value) :: {:ok, value} | {:error, CommandError.t()}

  @spec biot_id(params()) :: result(BiotId.t())
  def biot_id(path) do
    with {:ok, fields} <- collect(id: required(path, "id", &BiotId.parse/1)) do
      {:ok, fields.id}
    end
  end

  @spec create(params(), params()) :: result({BiotId.t(), Create.t()})
  def create(path, body) do
    with {:ok, fields} <-
           collect(
             id: required(path, "id", &BiotId.parse/1),
             name: required(body, "name", &BiotName.parse/1),
             repository: required(body, "repository", &RepositorySource.parse/1),
             environment: required(body, "environment", &EnvironmentSelection.parse/1),
             node_id: optional(body, "node_id", &NodeId.parse/1, :default),
             initial_state: optional(body, "initial_state", &initial_state/1, :running)
           ) do
      {:ok,
       {fields.id,
        %Create{
          name: fields.name,
          repository: fields.repository,
          environment: fields.environment,
          node_id: fields.node_id,
          initial_state: fields.initial_state
        }}}
    end
  end

  @doc "The Biot and expected revision for `start` and `stop`."
  @spec lifecycle_change(params(), params()) :: result({BiotId.t(), pos_integer()})
  def lifecycle_change(path, body) do
    with {:ok, fields} <-
           collect(
             id: required(path, "id", &BiotId.parse/1),
             expected_revision: required(body, "expected_revision", &revision/1)
           ) do
      {:ok, {fields.id, fields.expected_revision}}
    end
  end

  @spec environment_change(params(), params()) ::
          result({BiotId.t(), SelectEnvironment.t(), pos_integer()})
  def environment_change(path, body) do
    with {:ok, fields} <-
           collect(
             id: required(path, "id", &BiotId.parse/1),
             environment: required(body, "environment", &EnvironmentSelection.parse/1),
             expected_revision: required(body, "expected_revision", &revision/1)
           ) do
      {:ok,
       {fields.id, %SelectEnvironment{selection: fields.environment}, fields.expected_revision}}
    end
  end

  @doc "The Biot and port of a publication path."
  @spec publication(params()) :: result({BiotId.t(), Port.t()})
  def publication(path) do
    with {:ok, fields} <-
           collect(
             id: required(path, "id", &BiotId.parse/1),
             port: required(path, "port", &Port.parse/1)
           ) do
      {:ok, {fields.id, fields.port}}
    end
  end

  @doc "The published hostname, handoff challenge digest, and return path from a preview request."
  @spec preview_authorize(params()) :: result({Hostname.t(), Digest.t(), SameOriginPath.t()})
  def preview_authorize(query) do
    with {:ok, fields} <-
           collect(
             host: required(query, "host", &Hostname.parse/1),
             challenge: required(query, "challenge", &Digest.parse/1),
             return: required(query, "return", &SameOriginPath.parse/1)
           ) do
      {:ok, {fields.host, fields.challenge, fields.return}}
    end
  end

  @doc "The Biot and grantee of a shell grant path."
  @spec shell_grant(params()) :: result({BiotId.t(), PrincipalId.t()})
  def shell_grant(path) do
    with {:ok, fields} <-
           collect(
             id: required(path, "id", &BiotId.parse/1),
             principal_id: required(path, "principal_id", &PrincipalId.parse/1)
           ) do
      {:ok, {fields.id, fields.principal_id}}
    end
  end

  @doc "The Biot, port, and grantee of a view grant path."
  @spec view_grant(params()) :: result({BiotId.t(), Port.t(), PrincipalId.t()})
  def view_grant(path) do
    with {:ok, fields} <-
           collect(
             id: required(path, "id", &BiotId.parse/1),
             port: required(path, "port", &Port.parse/1),
             principal_id: required(path, "principal_id", &PrincipalId.parse/1)
           ) do
      {:ok, {fields.id, fields.port, fields.principal_id}}
    end
  end

  @doc "The Biot and name of a secret path."
  @spec secret(params()) :: result({BiotId.t(), SecretName.t()})
  def secret(path) do
    with {:ok, fields} <-
           collect(
             id: required(path, "id", &BiotId.parse/1),
             name: required(path, "name", &SecretName.parse/1)
           ) do
      {:ok, {fields.id, fields.name}}
    end
  end

  @doc "The Biot and name of a secret path, and the secret value in the body."
  @spec secret_delivery(params(), params()) ::
          result({BiotId.t(), SecretName.t(), SecretValue.t()})
  def secret_delivery(path, body) do
    with {:ok, fields} <-
           collect(
             id: required(path, "id", &BiotId.parse/1),
             name: required(path, "name", &SecretName.parse/1),
             value: required(body, "value", &SecretValue.parse(&1, protocol_version()))
           ) do
      {:ok, {fields.id, fields.name, fields.value}}
    end
  end

  @doc "The Biot of a fetch credential path, and the source URL in the body."
  @spec fetch_credential(params(), params()) :: result({BiotId.t(), RepositorySource.t()})
  def fetch_credential(path, body) do
    with {:ok, fields} <-
           collect(
             id: required(path, "id", &BiotId.parse/1),
             source: required(body, "source", &RepositorySource.parse/1)
           ) do
      {:ok, {fields.id, fields.source}}
    end
  end

  @doc "The Biot of a fetch credential path, and the source URL and authorization value in the body."
  @spec fetch_credential_delivery(params(), params()) ::
          result({BiotId.t(), RepositorySource.t(), AuthorizationValue.t()})
  def fetch_credential_delivery(path, body) do
    with {:ok, fields} <-
           collect(
             id: required(path, "id", &BiotId.parse/1),
             source: required(body, "source", &RepositorySource.parse/1),
             value: required(body, "value", &AuthorizationValue.parse(&1, protocol_version()))
           ) do
      {:ok, {fields.id, fields.source, fields.value}}
    end
  end

  @spec operation_id(params()) :: result(OperationId.t())
  def operation_id(path) do
    with {:ok, fields} <- collect(id: required(path, "id", &OperationId.parse/1)) do
      {:ok, fields.id}
    end
  end

  @spec diagnostic_ref(params()) :: result(PrivateDiagnosticId.t())
  def diagnostic_ref(path) do
    with {:ok, fields} <- collect(ref: required(path, "ref", &PrivateDiagnosticId.parse/1)) do
      {:ok, fields.ref}
    end
  end

  @doc """
  The Biot of a runtime log path, and the positive `max_bytes` in the query.

  `max_bytes` has no upper bound here, because `Biot.Server.RuntimeLogs.get/3` caps it at the
  server's response limit.
  """
  @spec runtime_logs(params(), params()) :: result({BiotId.t(), pos_integer()})
  def runtime_logs(path, query) do
    with {:ok, fields} <-
           collect(
             id: required(path, "id", &BiotId.parse/1),
             max_bytes: required(query, "max_bytes", &max_bytes/1)
           ) do
      {:ok, {fields.id, fields.max_bytes}}
    end
  end

  @doc "The email address in the query of a principal lookup."
  @spec principal_email(params()) :: result(String.t())
  def principal_email(query) do
    with {:ok, fields} <- collect(email: required(query, "email", &string/1)) do
      {:ok, fields.email}
    end
  end

  @spec credential_id(params()) :: result(CredentialId.t())
  def credential_id(path) do
    with {:ok, fields} <- collect(id: required(path, "id", &CredentialId.parse/1)) do
      {:ok, fields.id}
    end
  end

  @spec ssh_key_id(params()) :: result(SshKeyId.t())
  def ssh_key_id(path) do
    with {:ok, fields} <- collect(id: required(path, "id", &SshKeyId.parse/1)) do
      {:ok, fields.id}
    end
  end

  @doc """
  The public key line and label of a new SSH key.

  Both stay strings, because `Biot.Server.SshKeys.add/3` parses the key line and validates the
  label.
  """
  @spec ssh_key(params()) :: result({String.t(), String.t()})
  def ssh_key(body) do
    with {:ok, fields} <-
           collect(
             public_key: required(body, "public_key", &string/1),
             label: required(body, "label", &string/1)
           ) do
      {:ok, {fields.public_key, fields.label}}
    end
  end

  @doc "The page of a listing: the ID to list after, and a limit from 1 to 200 that defaults to 50."
  @spec page(params()) :: result(Biots.page())
  def page(query) do
    with {:ok, fields} <-
           collect(
             after: optional(query, "after", &BiotId.parse/1, nil),
             limit: optional(query, "limit", &page_limit/1, @default_page_limit)
           ) do
      {:ok, %{after: fields.after, limit: fields.limit}}
    end
  end

  defp collect(fields) do
    case for({field, {:error, reason}} <- fields, into: %{}, do: {field, [reason]}) do
      errors when map_size(errors) == 0 ->
        {:ok, Map.new(fields, fn {field, {:ok, value}} -> {field, value} end)}

      errors ->
        CommandError.invalid_input(errors)
    end
  end

  defp required(params, key, parse) do
    case Map.fetch(params, key) do
      {:ok, value} -> parse.(value)
      :error -> {:error, :missing}
    end
  end

  defp optional(params, key, parse, default) do
    case Map.get(params, key) do
      nil -> {:ok, default}
      value -> parse.(value)
    end
  end

  defp string(value) when is_binary(value), do: {:ok, value}
  defp string(_value), do: {:error, :invalid_format}

  defp initial_state("running"), do: {:ok, :running}
  defp initial_state("stopped"), do: {:ok, :stopped}
  defp initial_state(_value), do: {:error, :invalid_format}

  defp revision(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp revision(_value), do: {:error, :invalid_format}

  defp page_limit(value), do: query_integer(value, &(&1 in 1..@max_page_limit))

  defp max_bytes(value), do: query_integer(value, &(&1 > 0))

  # A query value is always a string, or a list or map when the key is repeated or nested.
  defp query_integer(value, in_range?) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> if in_range?.(integer), do: {:ok, integer}, else: {:error, :out_of_range}
      _error -> {:error, :invalid_format}
    end
  end

  defp query_integer(_value, _in_range?), do: {:error, :invalid_format}

  # A secret or authorization value crosses the control link, so its size bound belongs to a
  # protocol version. A request arrives before any link carries it, so it takes the bound of the
  # newest version the server speaks.
  defp protocol_version, do: Enum.max(Version.supported())
end
