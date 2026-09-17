defmodule BiotWeb.UserMessage do
  @moduledoc "The small, user-facing vocabulary for server and form results."

  alias Biot.Protocol.Failure
  alias Biot.Protocol.{FieldReason, Limits}
  alias Biot.Server.{CommandError, Policy}

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
    name_too_long:
      "is longer than #{Biot.Protocol.BiotName.max_length()} characters; shorten it.",
    invalid_value: "has an invalid value.",
    reserved_name: "is reserved; choose another name.",
    nul_byte: "must not contain a NUL byte.",
    secret_value_too_large:
      "is larger than #{Limits.max_secret_value_bytes(1)} bytes; shorten it.",
    too_many_layers: "has more than #{Limits.max_layers()} layers; remove one.",
    repository_url_too_long:
      "is longer than #{Limits.max_repository_url_bytes()} characters; shorten it.",
    source_ref_too_long:
      "is longer than #{Limits.max_source_ref_bytes()} characters; shorten it.",
    embedded_credentials:
      "must not embed credentials; deliver them as a source-fetch credential instead.",
    no_default_node: "is required because the server has no default node; choose one.",
    already_registered: "is already registered; use a different key.",
    not_future: "must be in the future; choose a later time.",
    too_far: "is beyond the allowed lifetime; choose an earlier time.",
    unknown_principal: "does not identify a known principal; check the email address.",
    not_ready: "is not ready yet.",
    publication_not_active: "is no longer active."
  }
  @field_reasons FieldReason.all()

  @command_error_sentences %{
    unauthenticated: "Your session is no longer valid.",
    not_found: "That resource was not found.",
    forbidden: "You do not have permission to do that.",
    invalid_input: "The request contains invalid input.",
    revision_conflict: "This Biot changed; its current revision is {revision}.",
    destroyed: "This Biot has been destroyed.",
    creation_conflict: "A Biot with that ID is already being created.",
    name_conflict: "That Biot name is already in use.",
    hostname_conflict: "That hostname is already in use.",
    node_disabled: "The selected node is disabled.",
    node_abandoned: "The selected node is abandoned.",
    capacity_exceeded: "The selected node has no available capacity.",
    temporarily_unavailable: "The server could not provide that resource right now."
  }

  @client_remedies %{
    unauthenticated: "Sign in again.",
    revision_conflict: "Reload and try again.",
    publication_not_active: "reload and choose an active one."
  }

  missing_field_sentences = FieldReason.all() -- Map.keys(@field_reason_sentences)

  if missing_field_sentences != [] do
    raise "BiotWeb.UserMessage has no sentence for field reasons: #{inspect(missing_field_sentences)}"
  end

  extra_field_sentences = Map.keys(@field_reason_sentences) -- FieldReason.all()

  if extra_field_sentences != [] do
    raise "BiotWeb.UserMessage has sentences for undeclared field reasons: #{inspect(extra_field_sentences)}"
  end

  missing_command_sentences = CommandError.all() -- Map.keys(@command_error_sentences)

  if missing_command_sentences != [] do
    raise "BiotWeb.UserMessage has no sentence for command errors: #{inspect(missing_command_sentences)}"
  end

  extra_command_sentences = Map.keys(@command_error_sentences) -- CommandError.all()

  if extra_command_sentences != [] do
    raise "BiotWeb.UserMessage has sentences for undeclared command errors: #{inspect(extra_command_sentences)}"
  end

  all_reasons = FieldReason.all() ++ CommandError.all()
  extra_client_remedies = Map.keys(@client_remedies) -- all_reasons

  if extra_client_remedies != [] do
    raise "BiotWeb.UserMessage has remedies for undeclared errors: #{inspect(extra_client_remedies)}"
  end

  for {reason, remedy} <- @client_remedies do
    kind = if reason in @field_reasons, do: :field, else: :command
    first = String.first(remedy)

    expected =
      if kind == :field, do: String.downcase(first || ""), else: String.upcase(first || "")

    if first == nil or first != expected do
      raise "BiotWeb.UserMessage has a #{kind} remedy with the wrong capitalization for #{reason}: #{inspect(remedy)}"
    end
  end

  @template_placeholders %{revision_conflict: ["revision"]}

  for {reason, sentence} <- Map.merge(@field_reason_sentences, @command_error_sentences) do
    placeholders =
      Regex.scan(~r/\{([a-z_][a-z0-9_]*)\}/, sentence, capture: :all_but_first)
      |> List.flatten()

    expected = Map.get(@template_placeholders, reason, [])

    if placeholders != expected or String.count(sentence, "{") != Enum.count(placeholders) or
         String.count(sentence, "}") != Enum.count(placeholders) do
      raise "BiotWeb.UserMessage has unexpected placeholders for #{reason}: #{inspect(placeholders)}"
    end
  end

  @doc "The generated field-reason sentences used by every client."
  @spec field_reason_sentences() :: %{atom() => String.t()}
  def field_reason_sentences, do: @field_reason_sentences

  @doc "The generated command-error sentences used by every client."
  @spec command_error_sentences() :: %{atom() => String.t()}
  def command_error_sentences, do: @command_error_sentences

  @doc "The client-specific remedies whose reason coverage is checked by the CLI artifact."
  @spec client_remedies() :: %{atom() => String.t()}
  def client_remedies, do: @client_remedies

  @spec error(
          CommandError.t()
          | FieldReason.t()
          | {:error, CommandError.t()}
          | {:uncertain, CommandError.t()}
          | Failure.t()
        ) :: String.t()
  def error({:error, reason}), do: error(reason)

  def error(%Failure{} = failure), do: failure_message(failure)

  def error({:invalid_input, fields}) when is_map(fields), do: invalid_fields(fields)

  def error({:uncertain, reason}),
    do: "The result is uncertain: " <> error(reason)

  def error({:revision_conflict, revision}),
    do: command_sentence(:revision_conflict, revision: to_string(revision))

  def error(:unauthenticated), do: command_sentence(:unauthenticated)
  def error(:not_found), do: command_sentence(:not_found)
  def error(:forbidden), do: command_sentence(:forbidden)
  def error(:destroyed), do: command_sentence(:destroyed)
  def error(:creation_conflict), do: command_sentence(:creation_conflict)
  def error(:name_conflict), do: command_sentence(:name_conflict)
  def error(:hostname_conflict), do: command_sentence(:hostname_conflict)
  def error(:node_disabled), do: command_sentence(:node_disabled)
  def error(:node_abandoned), do: command_sentence(:node_abandoned)
  def error(:capacity_exceeded), do: command_sentence(:capacity_exceeded)
  def error(:temporarily_unavailable), do: command_sentence(:temporarily_unavailable)

  def error(reason) when reason in @field_reasons,
    do: field_reason_sentence(reason)

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

  @spec field_error(atom(), FieldReason.t()) :: String.t()
  def field_error(field, reason), do: field_label(field) <> " " <> field_reason_sentence(reason)

  @spec enforcement(Policy.enforcement()) :: String.t()
  def enforcement(:applied), do: "enforcement applied"
  def enforcement({:pending, node_id}), do: "access update pending on #{node_id}"

  defp invalid_fields(fields) do
    fields
    |> Enum.sort_by(fn {field, _errors} -> field_label(field) end)
    |> Enum.map_join("; ", fn {field, errors} ->
      Enum.map_join(List.wrap(errors), ", ", &field_error(field, &1))
    end)
  end

  defp field_label(field), do: Map.get(@field_labels, field, "field")

  defp command_sentence(reason, replacements \\ []) do
    sentence =
      Enum.reduce(replacements, Map.fetch!(@command_error_sentences, reason), fn {key, value},
                                                                                 acc ->
        String.replace(acc, "{" <> to_string(key) <> "}", value)
      end)

    if Regex.match?(~r/\{[a-z_][a-z0-9_]*\}/, sentence),
      do: raise("BiotWeb.UserMessage left a placeholder in #{reason}: #{sentence}"),
      else: sentence_with_remedy(reason, sentence)
  end

  defp field_reason_sentence(reason),
    do: sentence_with_remedy(reason, Map.fetch!(@field_reason_sentences, reason))

  defp sentence_with_remedy(reason, sentence) do
    case Map.get(@client_remedies, reason) do
      nil ->
        sentence

      remedy when reason in @field_reasons ->
        String.trim_trailing(sentence, ".") <> "; " <> remedy

      remedy ->
        sentence <> " " <> remedy
    end
  end
end
