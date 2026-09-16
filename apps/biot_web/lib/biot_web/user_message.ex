defmodule BiotWeb.UserMessage do
  @moduledoc "The small, user-facing vocabulary for server and form results."

  alias Biot.Protocol.Failure

  @field_labels %{
    repository: "repository",
    name: "name",
    node_id: "node",
    environment: "environment",
    initial_state: "initial state",
    runtime_secrets: "runtime secrets",
    source_credentials: "source-fetch credentials",
    port: "port",
    email: "email",
    kind: "grant",
    value: "value",
    label: "label",
    expires_at: "expiry",
    public_key: "public key",
    id: "id",
    form: "form"
  }

  @spec error(term()) :: String.t()
  def error({:error, reason}), do: error(reason)

  def error(%Failure{} = failure), do: failure_message(failure)

  def error({:invalid_input, fields}) when is_map(fields), do: invalid_fields(fields)

  def error({:uncertain, reason}),
    do: "The result is uncertain: " <> error(reason)

  def error({:revision_conflict, revision}),
    do: "This Biot changed; its current revision is #{revision}. Reload and try again."

  def error(:unauthenticated), do: "Your session is no longer valid. Sign in again."
  def error(:forbidden), do: "You do not have permission to do that."
  def error(:not_found), do: "That resource was not found."
  def error(:temporarily_unavailable), do: "The server could not provide that resource right now."
  def error(:destroyed), do: "This Biot has been destroyed."
  def error(:creation_conflict), do: "A Biot with that ID is already being created."
  def error(:name_conflict), do: "That Biot name is already in use."
  def error(:hostname_conflict), do: "That hostname is already in use."
  def error(:node_disabled), do: "The selected node is disabled."
  def error(:node_abandoned), do: "The selected node is abandoned."
  def error(:capacity_exceeded), do: "The selected node has no available capacity."
  def error(:not_requested), do: "The node is not currently requesting a credential."
  def error(:publication_not_active), do: "That publication is no longer active."
  def error(:missing), do: "is required."
  def error(:invalid_format), do: "has an invalid format."
  def error(:out_of_range), do: "is outside the allowed range."
  def error(:too_long), do: "is too long."
  def error(:too_short), do: "is too short."
  def error(:invalid_value), do: "has an invalid value."
  def error(:not_ready), do: "is not ready yet."
  def error(:unknown_principal), do: "That principal could not be found."

  def error({_kind, _detail}), do: "The server rejected that request."
  def error(_reason), do: "The server could not complete that request."

  @spec failure_label(Failure.t()) :: String.t()
  def failure_label(%Failure{stage: stage, code: code}), do: "#{stage} / #{code}"

  @spec failure_message(Failure.t()) :: String.t()
  def failure_message(%Failure{} = failure),
    do: failure_label(failure) <> ": " <> failure.message

  @spec field_errors(term(), atom()) :: [term()]
  def field_errors({:invalid_input, fields}, field) when is_map(fields),
    do: Map.get(fields, field, [])

  def field_errors(_error, _field), do: []

  @spec field_error(atom(), term()) :: String.t()
  def field_error(field, reason), do: field_label(field) <> " " <> reason_text(reason)

  @spec enforcement(term()) :: String.t()
  def enforcement(:applied), do: "enforcement applied"
  def enforcement({:pending, node_id}), do: "access update pending on #{node_id}"
  def enforcement(_unknown), do: "enforcement status unavailable"

  defp invalid_fields(fields) do
    fields
    |> Enum.sort_by(fn {field, _errors} -> field_label(field) end)
    |> Enum.map_join("; ", fn {field, errors} ->
      Enum.map_join(List.wrap(errors), ", ", &field_error(field, &1))
    end)
  end

  defp field_label(field), do: Map.get(@field_labels, field, "field")

  defp reason_text(reason) when is_atom(reason), do: error(reason)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(_reason), do: "has an invalid value."
end
