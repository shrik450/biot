defmodule Biot.Node.RetryState do
  @moduledoc """
  What one biot's controller has already spent on its current desired revision: the attempts it has
  made per lifecycle stage, the failure it recorded, and when the next automatic attempt is due.

  The journal holds this record, so a controller crash or a node restart cannot reset an attempt
  budget or lose a pending backoff. The controller writes an attempt before it starts the action it
  counts, which is why an interrupted attempt still costs the budget.

  Every field describes one `target_revision`. A new desired revision supersedes the whole record.
  """

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Failure

  @typedoc "How many attempts this revision has spent on each lifecycle stage."
  @type attempts :: %{Failure.stage() => pos_integer()}

  @enforce_keys [:biot_id, :target_revision, :attempts, :next_attempt_at, :failure]
  defstruct [:biot_id, :target_revision, :attempts, :next_attempt_at, :failure]

  @type t :: %__MODULE__{
          biot_id: BiotId.t(),
          target_revision: pos_integer(),
          attempts: attempts(),
          next_attempt_at: DateTime.t() | nil,
          failure: Failure.t() | nil
        }

  @doc "The state of a biot that has spent nothing on this desired revision yet."
  @spec new(BiotId.t(), pos_integer()) :: t()
  def new(%BiotId{} = biot_id, target_revision) when target_revision > 0 do
    %__MODULE__{
      biot_id: biot_id,
      target_revision: target_revision,
      attempts: %{},
      next_attempt_at: nil,
      failure: nil
    }
  end

  @doc """
  The record that describes `revision`. A record of another desired revision describes work that
  revision superseded, so it never carries attempts or a failure forward.
  """
  @spec for_revision(t() | nil, BiotId.t(), pos_integer()) :: t()
  def for_revision(%__MODULE__{target_revision: revision} = state, _biot_id, revision), do: state
  def for_revision(_state, %BiotId{} = biot_id, revision), do: new(biot_id, revision)

  @doc "How many attempts one stage has spent, counting none as zero."
  @spec attempts(t(), Failure.stage()) :: non_neg_integer()
  def attempts(%__MODULE__{attempts: attempts}, stage), do: Map.get(attempts, stage, 0)

  @doc "The same state with one more attempt counted for `stage` and no attempt pending."
  @spec count_attempt(t(), Failure.stage()) :: t()
  def count_attempt(%__MODULE__{} = state, stage) do
    %{
      state
      | attempts: Map.update(state.attempts, stage, 1, &(&1 + 1)),
        next_attempt_at: nil
    }
  end
end
