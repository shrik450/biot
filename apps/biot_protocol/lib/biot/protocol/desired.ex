defmodule Biot.Protocol.Desired do
  @moduledoc "The server-owned execution intent for a biot."

  alias Biot.Protocol.EnvironmentId

  @enforce_keys [:revision, :state, :environment_id]
  defstruct [:revision, :state, :environment_id]

  @type state :: :running | :stopped | :destroyed
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
end
