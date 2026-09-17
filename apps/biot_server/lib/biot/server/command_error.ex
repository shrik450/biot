defmodule Biot.Server.CommandError do
  @moduledoc "The expected errors returned by server application functions."

  alias Biot.Protocol.FieldReason

  @type field_errors :: %{optional(atom()) => [FieldReason.t()]}

  @reasons [
    {:unauthenticated, :unauthenticated},
    {:not_found, :not_found},
    {:forbidden, :forbidden},
    {:invalid_input, quote(do: {:invalid_input, field_errors()})},
    {:revision_conflict, quote(do: {:revision_conflict, pos_integer()})},
    {:destroyed, :destroyed},
    {:creation_conflict, :creation_conflict},
    {:name_conflict, :name_conflict},
    {:hostname_conflict, :hostname_conflict},
    {:node_disabled, :node_disabled},
    {:node_abandoned, :node_abandoned},
    {:capacity_exceeded, :capacity_exceeded},
    {:temporarily_unavailable, :temporarily_unavailable}
  ]

  @type t ::
          unquote(
            @reasons
            |> Enum.map(&elem(&1, 1))
            |> Enum.reduce(fn reason, acc -> {:|, [], [reason, acc]} end)
          )

  @doc "Every command error tag, including errors carrying detail."
  @spec all() :: [atom()]
  def all, do: Enum.map(@reasons, &elem(&1, 0))

  @doc "Whether `reason` is a declared command error tag."
  @spec member?(term()) :: boolean()
  def member?(reason), do: reason in all()

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
