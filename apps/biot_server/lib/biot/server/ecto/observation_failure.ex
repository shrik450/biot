defmodule Biot.Server.Ecto.ObservationFailure do
  @moduledoc "Stores an observation failure and its target revision as tagged JSON."

  use Ecto.Type

  alias Biot.Protocol.Failure
  alias Biot.Server.Ecto.Json

  @type observation_failure :: nil | {pos_integer(), Failure.t()}

  @impl true
  def type, do: :map

  @impl true
  def cast(nil), do: {:ok, nil}

  def cast({target_revision, %Failure{}} = failure)
      when is_integer(target_revision) and target_revision > 0,
      do: {:ok, failure}

  def cast(_value), do: :error

  @impl true
  def load(nil), do: {:ok, nil}

  def load(value) do
    with {:ok, target_revision} when is_integer(target_revision) and target_revision > 0 <-
           Json.fetch(value, "target_revision"),
         {:ok, failure_value} <- Json.fetch(value, "failure"),
         {:ok, failure} <- Failure.parse(failure_value) do
      {:ok, {target_revision, failure}}
    else
      _error -> Json.corrupt!(__MODULE__, value)
    end
  end

  @impl true
  def dump(nil), do: {:ok, nil}

  def dump({target_revision, %Failure{} = failure})
      when is_integer(target_revision) and target_revision > 0 do
    {:ok,
     %{
       "target_revision" => target_revision,
       "failure" => Failure.encode(failure)
     }}
  end

  def dump(_value), do: :error
end
