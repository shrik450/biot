defmodule BiotWeb.Api.ErrorResponse do
  @moduledoc """
  Maps a `CommandError` to its HTTP status and JSON body, using the table in model section 3.

  The body is `{"error": tag}` with the tag's fields beside it: `fields` for `invalid_input` and
  `current_revision` for `revision_conflict`.
  """

  alias Biot.Server.CommandError

  @conflicts [
    :destroyed,
    :creation_conflict,
    :name_conflict,
    :hostname_conflict,
    :node_disabled,
    :node_abandoned,
    :capacity_exceeded
  ]

  @spec build(CommandError.t()) :: {pos_integer(), %{String.t() => term()}}
  def build(:unauthenticated), do: {401, tagged(:unauthenticated)}
  def build(:forbidden), do: {403, tagged(:forbidden)}
  def build(:not_found), do: {404, tagged(:not_found)}

  def build({:invalid_input, fields}),
    do: {422, Map.put(tagged(:invalid_input), "fields", encode_fields(fields))}

  def build({:revision_conflict, current_revision}),
    do: {409, Map.put(tagged(:revision_conflict), "current_revision", current_revision)}

  def build(conflict) when conflict in @conflicts, do: {409, tagged(conflict)}
  def build(:temporarily_unavailable), do: {503, tagged(:temporarily_unavailable)}

  defp tagged(tag), do: %{"error" => Atom.to_string(tag)}

  defp encode_fields(fields) do
    Map.new(fields, fn {field, reasons} ->
      {Atom.to_string(field), Enum.map(reasons, &to_string/1)}
    end)
  end
end
