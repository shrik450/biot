defmodule Biot.Protocol.SecretOutcome do
  @moduledoc """
  What a node can answer to a secret or fetch credential request.

  The three result messages share this union, so there is one statement of what the node can say
  and one codec for it. `no_allocation` is the model's own answer for a biot this node holds no
  allocation for, and it stays distinct from a failure because it is the expected state during
  creation rather than something that went wrong.

  A code names a cause an operator can act on. It never carries a value, a name, or a path.
  """

  alias Biot.Protocol.Choice
  alias Biot.Protocol.ParsedList
  alias Biot.Protocol.SecretName
  alias Biot.Protocol.StrictMap

  @codes ~w(write_failed unavailable)a

  @type code :: :write_failed | :unavailable
  @type t :: :ok | :no_allocation | {:failure, code()}
  @type listing :: {:ok, [SecretName.t()]} | :no_allocation | {:failure, code()}

  @spec codes() :: [code()]
  def codes, do: @codes

  @spec encode(t()) :: map()
  def encode(:ok), do: %{"status" => "ok"}
  def encode(:no_allocation), do: %{"status" => "no_allocation"}

  def encode({:failure, code}) when code in @codes do
    %{"status" => "failure", "code" => Atom.to_string(code)}
  end

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(%{"status" => "ok"} = value) do
    with {:ok, _value} <- StrictMap.fetch_exact(value, ["status"]), do: {:ok, :ok}
  end

  def parse(%{"status" => "no_allocation"} = value) do
    with {:ok, _value} <- StrictMap.fetch_exact(value, ["status"]), do: {:ok, :no_allocation}
  end

  def parse(%{"status" => "failure", "code" => code} = value) do
    with {:ok, _value} <- StrictMap.fetch_exact(value, ["status", "code"]),
         {:ok, code} <- Choice.parse(code, @codes) do
      {:ok, {:failure, code}}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec encode_listing(listing()) :: map()
  def encode_listing({:ok, names}) do
    %{"status" => "ok", "names" => Enum.map(names, &SecretName.to_string/1)}
  end

  def encode_listing(outcome), do: encode(outcome)

  @spec parse_listing(term()) :: {:ok, listing()} | {:error, :invalid_format}
  # A listing that succeeded carries names, so `ok` without them is malformed rather than the bare
  # `ok` a delivery answers with. Only the outcomes a listing shares with a delivery fall through.
  def parse_listing(%{"status" => "ok"} = value) do
    with {:ok, %{"names" => names}} <- StrictMap.fetch_exact(value, ["status", "names"]),
         {:ok, names} <- ParsedList.parse(names, &SecretName.parse/1) do
      {:ok, {:ok, names}}
    else
      _error -> {:error, :invalid_format}
    end
  end

  def parse_listing(value), do: parse(value)
end
