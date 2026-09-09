defmodule Biot.Server.Ecto.EnvironmentResolution do
  @moduledoc "Stores an environment resolution as one JSON value so manifests remain atomic protocol structs."

  use Ecto.Type

  alias Biot.Protocol.Manifest
  alias Biot.Server.Ecto.Json

  @type resolution :: :unresolved | {:resolved, Manifest.t()}

  @impl true
  def type, do: :map

  @impl true
  def cast(:unresolved), do: {:ok, :unresolved}
  def cast({:resolved, %Manifest{} = manifest}), do: {:ok, {:resolved, manifest}}
  def cast(_value), do: :error

  @impl true
  def load(value) do
    case Json.fetch(value, "state") do
      {:ok, "unresolved"} -> {:ok, :unresolved}
      {:ok, "resolved"} -> parse_manifest(value)
      _error -> Json.corrupt!(__MODULE__, value)
    end
  end

  @impl true
  def dump(:unresolved), do: {:ok, %{"state" => "unresolved"}}

  def dump({:resolved, %Manifest{} = manifest}),
    do: {:ok, %{"state" => "resolved", "manifest" => Manifest.encode(manifest)}}

  def dump(_value), do: :error

  defp parse_manifest(value) do
    with {:ok, manifest_value} <- Json.fetch(value, "manifest"),
         {:ok, manifest} <- Manifest.parse(manifest_value) do
      {:ok, {:resolved, manifest}}
    else
      _error -> Json.corrupt!(__MODULE__, value)
    end
  end
end
