defmodule Biot.Server.Queries.SecretView do
  @moduledoc """
  One runtime secret a biot holds, as its owner sees it.

  A name is all there is to project. There is no value-read API and no per-name server history, so
  this view cannot grow a field the server does not have.
  """

  alias Biot.Protocol.SecretName

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{name: SecretName.t()}

  @spec project(SecretName.t()) :: t()
  def project(%SecretName{} = name), do: %__MODULE__{name: name}
end
