defmodule Biot.Server.CommandError do
  @moduledoc "The expected errors returned by server application functions."

  alias Biot.Protocol.FieldReason

  @type field_errors :: %{optional(atom()) => [FieldReason.t()]}
  @type t ::
          :unauthenticated
          | :not_found
          | :forbidden
          | {:invalid_input, field_errors()}
          | {:revision_conflict, pos_integer()}
          | :destroyed
          | :creation_conflict
          | :name_conflict
          | :hostname_conflict
          | :node_disabled
          | :node_abandoned
          | :capacity_exceeded
          | :temporarily_unavailable

  @doc """
  Builds the one `invalid_input` error shape.

  Every reason must belong to `Biot.Protocol.FieldReason`, so a reason invented at an emitting
  site fails loudly here rather than reaching a client as a sentence nobody wrote.
  """
  @spec invalid_input(%{atom() => [FieldReason.t()]}) ::
          {:error, {:invalid_input, field_errors()}}
  def invalid_input(fields) when is_map(fields) do
    Enum.each(fields, fn {field, reasons} ->
      Enum.each(List.wrap(reasons), &check_reason!(field, &1))
    end)

    {:error, {:invalid_input, fields}}
  end

  defp check_reason!(field, reason) do
    if FieldReason.member?(reason) do
      :ok
    else
      raise ArgumentError,
            "unknown field reason #{inspect(reason)} for #{inspect(field)}; " <>
              "add it to Biot.Protocol.FieldReason and give it a sentence in BiotWeb.UserMessage"
    end
  end
end
