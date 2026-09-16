defmodule BiotWeb.ClosedVocabularyTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BiotWeb.Components.Role
  alias BiotWeb.Components.Status
  alias BiotWeb.Live.BiotTabs
  alias BiotWeb.TestFixtures
  alias BiotWeb.UserMessage

  @tabs [:overview, :publications, :access, :secrets, :logs]

  test "BiotTabs visibility is exhaustive for every role and tab" do
    roles = [
      {:owner, :owner},
      {:shell, {:collaborator, %{shell: true, view_ports: []}}},
      {:shell_and_view, {:collaborator, %{shell: true, view_ports: [TestFixtures.port(3000)]}}},
      {:view, {:collaborator, %{shell: false, view_ports: [TestFixtures.port(3000)]}}},
      {:collaborator, {:collaborator, %{shell: false, view_ports: []}}}
    ]

    expected = %{
      owner: MapSet.new([:publications, :access, :secrets, :logs]),
      shell: MapSet.new([:publications, :logs]),
      shell_and_view: MapSet.new([:publications, :logs]),
      view: MapSet.new([:publications]),
      collaborator: MapSet.new([:publications])
    }

    for {name, role} <- roles, tab <- @tabs do
      assert BiotTabs.visible?(%{role: role}, tab) == MapSet.member?(expected[name], tab),
             "unexpected visibility for #{name}/#{tab}"
    end
  end

  test "UserMessage covers every CommandError variant with its public wording" do
    expected = %{
      unauthenticated: "Your session is no longer valid. Sign in again.",
      not_found: "That resource was not found.",
      forbidden: "You do not have permission to do that.",
      destroyed: "This Biot has been destroyed.",
      creation_conflict: "A Biot with that ID is already being created.",
      name_conflict: "That Biot name is already in use.",
      hostname_conflict: "That hostname is already in use.",
      node_disabled: "The selected node is disabled.",
      node_abandoned: "The selected node is abandoned.",
      capacity_exceeded: "The selected node has no available capacity.",
      temporarily_unavailable: "The server could not provide that resource right now."
    }

    for {error, message} <- expected, do: assert(UserMessage.error(error) == message)

    assert UserMessage.error({:revision_conflict, 9}) =~ "current revision is 9"

    assert UserMessage.error({:invalid_input, %{name: [:missing], port: [:out_of_range]}}) ==
             "name is required.; port is outside the allowed range."
  end

  test "status component covers every status label and visual class" do
    statuses = [
      {:enabled, "enabled", "healthy"},
      {:disabled, "disabled", "attention"},
      {:retired, "retired", "attention"},
      {:abandoned, "abandoned", "attention"},
      {:connecting, "connecting", "pending"},
      {:ready, "ready", "healthy"},
      {:unavailable, "unavailable", "attention"},
      {:never_reported, "never reported", "unknown"}
    ]

    for {status, label, class} <- statuses do
      assert Status.label(status) == label
      assert Status.class(status) == class
      html = render_component(&Status.status/1, value: status)
      assert html =~ "status-#{class}"
      assert html =~ label
    end
  end

  test "role component covers every role projection" do
    roles = [
      {:owner, "owner"},
      {{:collaborator, %{shell: true, view_ports: []}}, "collaborator · shell"},
      {{:collaborator, %{shell: true, view_ports: [TestFixtures.port(3000)]}},
       "collaborator · shell, view 3000"},
      {{:collaborator, %{shell: false, view_ports: [TestFixtures.port(3000)]}},
       "collaborator · view 3000"},
      {{:collaborator, %{shell: false, view_ports: []}}, "collaborator · view"}
    ]

    for {role, label} <- roles do
      assert Role.label(role) == label
      assert render_component(&Role.role/1, role: role) =~ label
    end
  end
end
