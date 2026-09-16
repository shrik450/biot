defmodule BiotWeb.Live.ShellAvailability do
  @moduledoc "Pure rule for whether a projected Biot can expose a shell entry point."

  alias Biot.Server.Queries.BiotView

  @spec allowed?(BiotView.t() | map()) :: boolean()
  def allowed?(%{
        role: role,
        node: :ready,
        desired: %{state: state},
        actual: %{container: {:present, _incarnation, :running}}
      })
      when state != :destroyed do
    role == :owner or match?({:collaborator, %{shell: true}}, role)
  end

  def allowed?(_view), do: false
end
