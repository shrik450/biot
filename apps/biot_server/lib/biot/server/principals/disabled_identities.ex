defmodule Biot.Server.Principals.DisabledIdentities do
  @moduledoc "Loads the operator's file of disabled issuer and subject identities."

  alias Biot.Server.OperatorFile

  defmodule Identity do
    @moduledoc "One OIDC identity the operator has disabled."

    @enforce_keys [:issuer, :subject]
    defstruct [:issuer, :subject]

    @type t :: %__MODULE__{issuer: String.t(), subject: String.t()}
  end

  @type error :: OperatorFile.error(:invalid_format | {:issuer | :subject, atom()})

  @spec load() :: {:ok, [Identity.t()]} | {:error, error()}
  def load do
    :biot_server
    |> Application.get_env(:disabled_principals_file)
    |> OperatorFile.load(&parse_identity/1)
  end

  @spec message(error()) :: String.t()
  def message(error), do: OperatorFile.message("disabled principals", error)

  defp parse_identity(value) when is_map(value) do
    with {:ok, issuer} <- field(value, "issuer", :issuer),
         {:ok, subject} <- field(value, "subject", :subject) do
      {:ok, %Identity{issuer: issuer, subject: subject}}
    end
  end

  defp parse_identity(_value), do: {:error, :invalid_format}

  defp field(value, key, name) do
    case Map.fetch(value, key) do
      {:ok, text} when is_binary(text) and text != "" -> {:ok, text}
      {:ok, _value} -> {:error, {name, :invalid_format}}
      :error -> {:error, {name, :missing}}
    end
  end
end
