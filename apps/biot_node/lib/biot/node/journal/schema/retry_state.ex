defmodule Biot.Node.Journal.Schema.RetryState do
  @moduledoc "The journal row for one biot's retry budget and pending backoff."

  use Ecto.Schema

  alias Biot.Node.Journal.Ecto.Attempts
  alias Biot.Node.Journal.Ecto.Failure
  alias Biot.Node.Journal.Ecto.ParsedValue
  alias Biot.Protocol.BiotId

  @primary_key false
  schema "retry_states" do
    field(:biot_id, ParsedValue, module: BiotId, primary_key: true)
    field(:target_revision, :integer)
    field(:attempts, Attempts)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:failure, Failure)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
