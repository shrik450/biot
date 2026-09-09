defmodule Biot.Server.Nodes.Status do
  @moduledoc "Owns the server meaning of each node status."

  alias Biot.Protocol.Message
  alias Biot.Server.CommandError

  @type t :: :enabled | :disabled | :retired | :abandoned

  @spec terminal?(t()) :: boolean()
  def terminal?(:enabled), do: false
  def terminal?(:disabled), do: false
  def terminal?(:retired), do: true
  def terminal?(:abandoned), do: true

  @spec serves_access?(t()) :: boolean()
  def serves_access?(:enabled), do: true
  def serves_access?(:disabled), do: false
  def serves_access?(:retired), do: false
  def serves_access?(:abandoned), do: false

  @spec written_off?(t()) :: boolean()
  def written_off?(:enabled), do: false
  def written_off?(:disabled), do: false
  def written_off?(:retired), do: false
  def written_off?(:abandoned), do: true

  @spec accepts_connection(t()) :: :ok | {:error, Message.Reject.reason()}
  def accepts_connection(:enabled), do: :ok
  def accepts_connection(:disabled), do: :ok
  def accepts_connection(:retired), do: {:error, :registration_retired}
  def accepts_connection(:abandoned), do: {:error, :registration_abandoned}

  @spec accepts_new_biots(t()) :: :ok | {:error, CommandError.t()}
  def accepts_new_biots(:enabled), do: :ok
  def accepts_new_biots(:disabled), do: {:error, :node_disabled}

  # The command error vocabulary has no separate result for retired nodes.
  def accepts_new_biots(:retired), do: {:error, :node_disabled}

  def accepts_new_biots(:abandoned), do: {:error, :node_abandoned}

  @spec accepts_lifecycle_change(t()) :: :ok | {:error, CommandError.t()}
  def accepts_lifecycle_change(:enabled), do: :ok
  def accepts_lifecycle_change(:disabled), do: :ok
  def accepts_lifecycle_change(:retired), do: :ok
  def accepts_lifecycle_change(:abandoned), do: {:error, :node_abandoned}
end
