defmodule BiotWeb.UserMessage do
  @moduledoc "The small, user-facing vocabulary for server and form results."

  alias Biot.Protocol.Failure
  alias Biot.Protocol.FieldReason

  @field_labels %{
    repository: "repository",
    name: "name",
    node_id: "node",
    environment: "environment",
    initial_state: "initial state",
    runtime_secrets: "runtime secret",
    source_credentials: "source-fetch credential",
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

  # A field reason completes "<label> ...", so the sentence never repeats the label and, where
  # there is one, names the next step. `FieldReason.all/0` is the closed vocabulary; the check
  # below refuses to compile a browser that cannot say one of its reasons.
  @field_reason_sentences %{
    missing: "is required.",
    invalid_format: "has an invalid format.",
    out_of_range: "is outside the allowed range.",
    too_long: "is too long.",
    too_short: "is too short.",
    invalid_value: "has an invalid value.",
    reserved_name: "is reserved; choose another name.",
    nul_byte: "must not contain a NUL byte.",
    secret_value_too_large: "is larger than the maximum allowed size.",
    too_many_layers: "has too many layers; remove one.",
    repository_url_too_long: "is longer than the maximum repository URL length.",
    source_ref_too_long: "is longer than the maximum reference length.",
    embedded_credentials:
      "must not embed credentials; deliver them as a source-fetch credential instead.",
    no_default_node: "is required because the server has no default node; choose one.",
    already_registered: "is already registered; use a different key.",
    not_future: "must be in the future; choose a later time.",
    too_far: "is beyond the allowed lifetime; choose an earlier time.",
    unknown_principal: "does not identify a known principal; check the email address.",
    not_requested: "is not currently requested.",
    not_ready: "is not ready yet.",
    publication_not_active: "is no longer active; reload and choose an active one."
  }

  missing_sentences = FieldReason.all() -- Map.keys(@field_reason_sentences)

  if missing_sentences != [] do
    raise "BiotWeb.UserMessage has no sentence for field reasons: #{inspect(missing_sentences)}"
  end

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
  def error(:unknown_principal), do: "That principal could not be found."

  def error(reason) when is_atom(reason),
    do: Map.get(@field_reason_sentences, reason, "The server could not complete that request.")

  def error({_kind, _detail}), do: "The server rejected that request."
  def error(_reason), do: "The server could not complete that request."

  @doc """
  The sentence to show above a form, or nil when the inline field messages already say everything.

  `rendered_fields` names the fields whose message the form prints next to the input. A field
  reason for one of those stays with the input; a field reason for any other field, and every
  error that is not `:invalid_input`, stays here. Each message then appears exactly once.
  """
  @spec summary(term(), [atom()]) :: String.t() | nil
  def summary(nil, _rendered_fields), do: nil

  def summary({:invalid_input, fields}, rendered_fields) when is_map(fields) do
    unattached = Map.reject(fields, fn {field, _reasons} -> field in rendered_fields end)

    if map_size(unattached) == 0, do: nil, else: invalid_fields(unattached)
  end

  def summary(error, _rendered_fields), do: error(error)

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

  defp reason_text(reason) when is_atom(reason),
    do: Map.get(@field_reason_sentences, reason, "has an invalid value.")

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(_reason), do: "has an invalid value."
end
