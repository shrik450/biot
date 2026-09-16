defmodule BiotWeb.BiotState do
  @moduledoc "Pure decisions shared by Biot list, detail, and creation views."

  alias Biot.Protocol.Failure
  alias Biot.Server.Queries.BiotView
  alias Biot.Server.Queries.OperationView

  @spec current_failure(BiotView.t() | map()) :: Failure.t() | nil
  def current_failure(%{
        desired: %{revision: revision},
        operation: %OperationView{
          target_revision: revision,
          outcome: {:failed, failure}
        }
      }),
      do: failure

  def current_failure(%{
        desired: %{revision: revision},
        actual: %{failure: {revision, failure}}
      }),
      do: failure

  def current_failure(_view), do: nil
end
