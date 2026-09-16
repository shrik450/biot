defmodule BiotWeb.Components.Role do
  @moduledoc "Formats the projected Biot role without deriving permissions in the browser."

  use BiotWeb, :html

  alias Biot.Protocol.Port

  attr :role, :any, required: true

  @spec role(map()) :: Phoenix.LiveView.Rendered.t()
  def role(assigns) do
    ~H"""
    <span class="role-detail">{label(@role)}</span>
    """
  end

  @spec label(:owner | {:collaborator, map()}) :: String.t()
  def label(:owner), do: "owner"

  def label({:collaborator, %{shell: shell, view_ports: view_ports}}) do
    grants = []
    grants = if shell, do: ["shell" | grants], else: grants
    grants = if view_ports == [], do: grants, else: [ports(view_ports) | grants]

    case Enum.reverse(grants) do
      [] -> "collaborator · view"
      values -> "collaborator · " <> Enum.join(values, ", ")
    end
  end

  defp ports(view_ports) do
    "view " <> Enum.map_join(view_ports, ", ", &Port.to_string/1)
  end
end
