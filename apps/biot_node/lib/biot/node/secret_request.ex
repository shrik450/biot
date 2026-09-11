defmodule Biot.Node.SecretRequest do
  @moduledoc """
  One secret or fetch credential request a controller owes an answer to.

  The deadline is this node's own and starts when the connection received the request. It bounds how
  long a request may wait for the controller to reach a point where it can be served; past it, the
  answer is no longer the answer its caller is waiting for, so the request is dropped rather than
  performed. The server releases its caller on its own timer and ignores a late reply.

  `result_kind/1` is derived rather than carried, so the operation is the only thing that decides
  which result message the connection sends back.
  """

  alias Biot.Protocol.AuthorizationValue
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SecretName
  alias Biot.Protocol.SecretValue

  @typedoc "Everything a controller can be asked to do to a biot's secrets, and nothing else."
  @type operation ::
          {:deliver_secret, SecretName.t(), SecretValue.t()}
          | {:remove_secret, SecretName.t()}
          | :list_secrets
          | {:deliver_fetch_credential, RepositorySource.t(), AuthorizationValue.t()}
          | {:remove_fetch_credential, RepositorySource.t()}

  @typedoc "Which result message answers this request."
  @type result_kind :: :secret | :secret_list | :fetch_credential

  @enforce_keys [:request_id, :operation, :deadline, :reply_to]
  defstruct [:request_id, :operation, :deadline, :reply_to]

  @type t :: %__MODULE__{
          request_id: String.t(),
          operation: operation(),
          deadline: integer(),
          reply_to: pid()
        }

  @spec new(String.t(), operation(), pos_integer(), pid()) :: t()
  def new(request_id, operation, timeout_ms, reply_to) when is_pid(reply_to) do
    %__MODULE__{
      request_id: request_id,
      operation: operation,
      deadline: now() + timeout_ms,
      reply_to: reply_to
    }
  end

  @spec now() :: integer()
  def now, do: System.monotonic_time(:millisecond)

  @spec expired?(t(), integer()) :: boolean()
  def expired?(%__MODULE__{deadline: deadline}, now), do: now > deadline

  @spec result_kind(operation()) :: result_kind()
  def result_kind({:deliver_secret, _name, _value}), do: :secret
  def result_kind({:remove_secret, _name}), do: :secret
  def result_kind(:list_secrets), do: :secret_list
  def result_kind({:deliver_fetch_credential, _source, _value}), do: :fetch_credential
  def result_kind({:remove_fetch_credential, _source}), do: :fetch_credential
end
