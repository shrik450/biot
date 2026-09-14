defmodule BiotWeb.Api.Json do
  @moduledoc """
  Turns server views into the string-keyed maps that API responses send.

  An ID becomes a string through `to_string/1`, and a port becomes an integer. A time is an
  ISO 8601 string. An enum without data is a string. A union with data in any variant is an
  object with `"kind"` and that variant's fields beside it. A value that may be absent is `null`
  when it is absent.
  """

  alias Biot.Protocol.ContainerState
  alias Biot.Protocol.Desired
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Failure
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.OrphanedAllocation
  alias Biot.Protocol.Port
  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Policy
  alias Biot.Server.Queries.AccessView
  alias Biot.Server.Queries.BiotView
  alias Biot.Server.Queries.CredentialView
  alias Biot.Server.Queries.DeploymentView
  alias Biot.Server.Queries.NodeView
  alias Biot.Server.Queries.OperationView
  alias Biot.Server.Queries.PrincipalView
  alias Biot.Server.Queries.PublicationView
  alias Biot.Server.Queries.SecretView
  alias Biot.Server.Queries.SshKeyView

  @spec encode(
          PrincipalView.t()
          | BiotView.t()
          | OperationView.t()
          | AccessView.t()
          | PublicationView.t()
          | SecretView.t()
          | DeploymentView.t()
          | NodeView.t()
          | CredentialView.t()
          | SshKeyView.t()
        ) :: %{String.t() => term()}
  def encode(%PrincipalView{} = principal) do
    %{
      "id" => to_string(principal.id),
      "email" => principal.email,
      "name" => principal.name
    }
  end

  def encode(%BiotView{} = biot) do
    %{
      "id" => to_string(biot.id),
      "name" => biot.name,
      "owner_id" => to_string(biot.owner_id),
      "node_id" => to_string(biot.node_id),
      "role" => role(biot.role),
      "desired" => Desired.encode(biot.desired),
      "actual" => actual(biot.actual),
      "node" => Atom.to_string(biot.node),
      "operation" => operation(biot.operation),
      "access" => %{
        "revision" => biot.access.revision,
        "enforcement" => enforcement(biot.access.enforcement)
      },
      "publications" => Enum.map(biot.publications, &encode/1),
      "direct_secret_exposure_possible" => biot.direct_secret_exposure_possible
    }
  end

  def encode(%OperationView{} = operation) do
    %{
      "id" => to_string(operation.id),
      "kind" => Atom.to_string(operation.kind),
      "target_revision" => operation.target_revision,
      "outcome" => outcome(operation.outcome)
    }
  end

  def encode(%AccessView{} = access) do
    %{
      "owner_id" => to_string(access.owner_id),
      "shell_grants" => Enum.map(access.shell_grants, &to_string/1),
      "view_grants" =>
        Enum.map(access.view_grants, fn grant ->
          %{"port" => grant.port.value, "principal_id" => to_string(grant.principal_id)}
        end)
    }
  end

  def encode(%{port: %Port{} = port, url: url}), do: %{"port" => port.value, "url" => url}

  def encode(%SecretView{} = secret), do: %{"name" => to_string(secret.name)}

  def encode(%DeploymentView{} = deployment) do
    %{
      "publication_domain" => deployment.publication_domain,
      "ssh" => %{"host" => deployment.ssh.host, "port" => deployment.ssh.port}
    }
  end

  def encode(%NodeView{} = node) do
    %{
      "id" => to_string(node.id),
      "status" => Atom.to_string(node.status),
      "platform" => platform(node.platform),
      "max_biots" => node.max_biots,
      "assigned_biots" => node.assigned_biots,
      "connection" => Atom.to_string(node.connection),
      "orphans" => orphans(node.orphans)
    }
  end

  def encode(%CredentialView{} = credential) do
    %{
      "id" => to_string(credential.id),
      "label" => credential.label,
      "expires_at" => DateTime.to_iso8601(credential.expires_at),
      "last_used_at" => time(credential.last_used_at)
    }
  end

  def encode(%SshKeyView{} = key) do
    %{
      "id" => to_string(key.id),
      "public_key" => to_string(key.public_key),
      "fingerprint" => key.fingerprint,
      "label" => key.label
    }
  end

  @doc "Encodes the principal ID that `Biot.Server.Principals.resolve_email/2` returns."
  @spec principal_id(PrincipalId.t()) :: %{String.t() => String.t()}
  def principal_id(principal_id), do: %{"id" => to_string(principal_id)}

  @doc "Encodes the `{content, truncated}` result of `Biot.Server.Diagnostics.get/2`."
  @spec diagnostic({binary(), boolean()}) :: %{String.t() => term()}
  def diagnostic({content, truncated}),
    do: %{"content" => readable(content), "truncated" => truncated}

  @doc "Encodes the `{incarnation_id, content, truncated}` result of `Biot.Server.RuntimeLogs.get/3`."
  @spec runtime_logs({IncarnationId.t(), binary(), boolean()}) :: %{String.t() => term()}
  def runtime_logs({incarnation_id, content, truncated}) do
    %{
      "incarnation_id" => to_string(incarnation_id),
      "content" => readable(content),
      "truncated" => truncated
    }
  end

  @doc "Encodes whether the assigned node has applied a Biot's access revision."
  @spec enforcement(Policy.enforcement()) :: %{String.t() => String.t()}
  def enforcement(:applied), do: %{"kind" => "applied"}

  def enforcement({:pending, node_id}),
    do: %{"kind" => "pending", "node_id" => to_string(node_id)}

  defp role(:owner), do: %{"kind" => "owner"}

  defp role({:collaborator, %{shell: shell, view_ports: view_ports}}) do
    %{
      "kind" => "collaborator",
      "shell" => shell,
      "view_ports" => Enum.map(view_ports, & &1.value)
    }
  end

  defp actual(:never_reported), do: %{"kind" => "never_reported"}

  defp actual(actual) do
    %{
      "kind" => "reported",
      "received_at" => DateTime.to_iso8601(actual.received_at),
      "freshness" => Atom.to_string(actual.freshness),
      "installed_environment" => installed_environment(actual.installed_environment),
      "container" => container(actual.container),
      "data" => Atom.to_string(actual.data),
      "waiting_for" => ExecutionReport.encode_waiting_for(actual.waiting_for),
      "failure" => observed_failure(actual.failure)
    }
  end

  defp installed_environment(nil), do: nil
  defp installed_environment(environment_id), do: to_string(environment_id)

  defp container(:unknown), do: %{"kind" => "unknown"}
  defp container(:absent), do: %{"kind" => "absent"}

  defp container({:present, incarnation_id, state}) do
    state
    |> ContainerState.encode()
    |> Map.merge(%{"kind" => "present", "incarnation_id" => to_string(incarnation_id)})
  end

  defp observed_failure(nil), do: nil

  defp observed_failure({target_revision, failure}) do
    failure
    |> Failure.encode()
    |> Map.put("target_revision", target_revision)
  end

  defp platform(nil), do: nil
  defp platform(platform), do: to_string(platform)

  defp orphans(:never_reported), do: %{"kind" => "never_reported"}

  defp orphans(%{reported_at: reported_at, allocations: allocations}) do
    %{
      "kind" => "reported",
      "reported_at" => DateTime.to_iso8601(reported_at),
      "allocations" => Enum.map(allocations, &OrphanedAllocation.encode/1)
    }
  end

  defp time(nil), do: nil
  defp time(time), do: DateTime.to_iso8601(time)

  defp operation(nil), do: nil
  defp operation(%OperationView{} = operation), do: encode(operation)

  defp outcome({:failed, failure}), do: failure |> Failure.encode() |> Map.put("kind", "failed")
  defp outcome(outcome), do: %{"kind" => Atom.to_string(outcome)}

  # Node output is raw bytes, and a JSON string must be valid UTF-8. People read this content, so an
  # invalid sequence becomes U+FFFD rather than failing the whole response.
  defp readable(content), do: String.replace_invalid(content)
end
