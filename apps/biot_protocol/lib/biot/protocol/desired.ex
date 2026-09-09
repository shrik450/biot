defmodule Biot.Protocol.Desired do
  @moduledoc "The server-owned execution intent for a biot."

  alias Biot.Protocol.EnvironmentId

  @states [:running, :stopped, :destroyed]
  @type state :: :running | :stopped | :destroyed

  @enforce_keys [:revision, :state, :environment_id]
  defstruct [:revision, :state, :environment_id]

  @type change ::
          :start
          | :stop
          | {:update_environment, EnvironmentId.t()}
          | :destroy
  @type t :: %__MODULE__{
          revision: pos_integer(),
          state: state(),
          environment_id: EnvironmentId.t()
        }

  @spec states() :: [state()]
  def states, do: @states

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = desired) do
    %{
      "revision" => desired.revision,
      "state" => Atom.to_string(desired.state),
      "environment_id" => EnvironmentId.to_string(desired.environment_id)
    }
  end

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(%{"revision" => revision, "state" => state, "environment_id" => environment_id})
      when is_integer(revision) and revision > 0 do
    with {:ok, state} <- parse_state(state),
         {:ok, environment_id} <- EnvironmentId.parse(environment_id) do
      {:ok, %__MODULE__{revision: revision, state: state, environment_id: environment_id}}
    else
      _error -> {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec transition(t(), change()) :: {:changed, t()} | :unchanged | {:error, :destroyed}
  def transition(%__MODULE__{state: :destroyed}, :destroy), do: :unchanged
  def transition(%__MODULE__{state: :destroyed}, _change), do: {:error, :destroyed}

  def transition(%__MODULE__{state: :running}, :start), do: :unchanged
  def transition(%__MODULE__{state: :stopped}, :stop), do: :unchanged

  def transition(%__MODULE__{state: :stopped} = desired, :start) do
    {:changed, %{desired | revision: desired.revision + 1, state: :running}}
  end

  def transition(%__MODULE__{state: :running} = desired, :stop) do
    {:changed, %{desired | revision: desired.revision + 1, state: :stopped}}
  end

  def transition(%__MODULE__{} = desired, {:update_environment, environment_id}) do
    {:changed, %{desired | revision: desired.revision + 1, environment_id: environment_id}}
  end

  def transition(%__MODULE__{} = desired, :destroy) do
    {:changed, %{desired | revision: desired.revision + 1, state: :destroyed}}
  end

  defp parse_state(value) when is_binary(value) do
    case Enum.find(@states, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_format}
      state -> {:ok, state}
    end
  end

  defp parse_state(_state), do: {:error, :invalid_format}
end
