defmodule BiotWeb.Live.BiotDetailData do
  @moduledoc "Owns the server-backed reads used by one Biot detail page."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.RepositorySource
  alias Biot.Server.Actor
  alias Biot.Server.Queries.BiotDetailView
  alias Biot.Server.Queries.Deployment
  alias Biot.Server.Queries.SecretView
  alias Biot.Server.RuntimeLogs
  alias Biot.Server.Secrets

  @type detail_states :: %{
          detail_state: result(),
          deployment_state: result()
        }

  @type result :: {:ok, term()} | {:error, term()}

  @spec load(Actor.t() | nil, BiotId.t()) :: detail_states()
  def load(actor, %BiotId{} = biot_id) do
    %{
      detail_state: BiotDetailView.get(actor, biot_id),
      deployment_state: Deployment.get(actor)
    }
  end

  @spec load_secrets(Actor.t() | nil, BiotId.t()) ::
          {:ok, [SecretView.t()]} | {:error, term()}
  def load_secrets(actor, %BiotId{} = biot_id), do: Secrets.list(actor, biot_id)

  @spec load_logs(Actor.t() | nil, BiotId.t()) ::
          {:ok, {Biot.Protocol.IncarnationId.t(), binary(), boolean()}}
          | {:error, term()}
  def load_logs(actor, %BiotId{} = biot_id), do: RuntimeLogs.get(actor, biot_id)

  @spec waiting_fetch_source(map()) :: RepositorySource.t() | nil
  def waiting_fetch_source(%{
        actual: %{accepted_revision: revision, waiting_for: {:fetch_credential, source}},
        desired: %{revision: revision},
        operation: %{target_revision: revision, outcome: outcome}
      })
      when outcome in [:pending, :working] do
    case source do
      %RepositorySource{} = source -> source
      _invalid_source -> nil
    end
  end

  def waiting_fetch_source(_view), do: nil
end
