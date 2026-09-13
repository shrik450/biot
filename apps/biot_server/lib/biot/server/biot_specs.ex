defmodule Biot.Server.BiotSpecs do
  @moduledoc """
  Builds the `BiotSpec` a node receives from the Biot and Environment rows.

  It reads no policy or lifecycle command code, so the control connection can depend on it without
  depending on the modules that change Biots.
  """

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Environment

  @spec build(BiotId.t()) :: {:ok, BiotSpec.t()} | {:error, :not_found}
  def build(%BiotId{} = biot_id) do
    with %BiotRow{} = biot <- Repo.get(BiotRow, biot_id),
         %Environment{} = environment <- Repo.get(Environment, biot.desired_environment_id) do
      {:ok,
       %BiotSpec{
         execution: %ExecutionSpec{
           biot_id: biot.id,
           repository: biot.repository,
           desired: BiotRow.desired(biot),
           environment: %{id: environment.id, selection: environment.selection}
         },
         access_revision: biot.access_revision
       }}
    else
      nil -> {:error, :not_found}
    end
  end
end
