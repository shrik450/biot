defmodule BiotWeb.RoleComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BiotWeb.Components.Role
  alias BiotWeb.Live.BiotTabs
  alias BiotWeb.TestFixtures

  test "role component explains owner and collaborator permissions" do
    assert render_component(&Role.role/1, role: :owner) =~ "owner"

    assert render_component(&Role.role/1,
             role: {:collaborator, %{shell: true, view_ports: [TestFixtures.port(3000)]}}
           ) =~ "collaborator · shell, view 3000"

    assert render_component(&Role.role/1,
             role: {:collaborator, %{shell: false, view_ports: []}}
           ) =~ "collaborator · view"
  end

  test "tab visibility follows the projected role" do
    owner = %{role: :owner}
    shell = %{role: {:collaborator, %{shell: true, view_ports: []}}}
    viewer = %{role: {:collaborator, %{shell: false, view_ports: [TestFixtures.port(3000)]}}}

    assert BiotTabs.visible?(owner, :access)
    assert BiotTabs.visible?(owner, :secrets)
    assert BiotTabs.visible?(shell, :logs)
    refute BiotTabs.visible?(shell, :access)
    refute BiotTabs.visible?(viewer, :logs)
    assert BiotTabs.visible?(viewer, :publications)
  end
end
