defmodule Biot.Server.Nodes.Enrollment do
  @moduledoc """
  Builds the operator's node enrollment list.

  The Mix task that writes `BIOT_NODE_REGISTRATIONS` and the server that reads it share
  `Biot.Server.Nodes.Registration`, so an entry this module accepts is an entry the server accepts.
  """

  alias Biot.Server.Nodes.Registration

  @typedoc "One decoded enrollment entry, keyed the way the JSON file is."
  @type entry :: %{optional(String.t()) => term()}

  @doc "The entry that enrolls one registration, or nil when the list has none."
  @spec find([entry()], String.t()) :: entry() | nil
  def find(entries, registration_id) when is_list(entries) and is_binary(registration_id) do
    Enum.find(entries, &entry_for?(&1, registration_id))
  end

  @doc "Replaces the entry for the same registration, or appends it, ordered by registration ID."
  @spec upsert([entry()], entry()) :: [entry()]
  def upsert(entries, entry) when is_list(entries) and is_map(entry) do
    registration_id = Map.fetch!(entry, "registration_id")

    [entry | Enum.reject(entries, &entry_for?(&1, registration_id))]
    |> Enum.sort_by(&Map.fetch!(&1, "registration_id"))
  end

  @doc "Returns `:ok` when the server's own schema accepts the entry."
  @spec validate(entry()) :: :ok | {:error, term()}
  def validate(entry) when is_map(entry) do
    case Registration.parse(entry) do
      {:ok, _registration} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_entry), do: {:error, {:registration, :invalid_format}}

  defp entry_for?(entry, registration_id) when is_map(entry),
    do: Map.get(entry, "registration_id") == registration_id

  defp entry_for?(_entry, _registration_id), do: false
end
