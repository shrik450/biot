defmodule BiotWeb.ClosedVocabularyTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Biot.Protocol.FieldReason
  alias Biot.Server.CommandError
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

  test "every field reason has a distinct non-generic rendered sentence" do
    messages =
      for reason <- FieldReason.all(), into: %{} do
        {reason, UserMessage.error({:invalid_input, %{kind: [reason]}})}
      end

    assert map_size(messages) == length(FieldReason.all())

    for {reason, message} <- messages do
      assert String.starts_with?(message, "grant "), "#{reason} was not rendered as a field"
      refute message == "The server could not complete that request."
    end

    assert map_size(Map.new(messages, fn {_reason, message} -> {message, true} end)) ==
             length(FieldReason.all())
  end

  test "an unknown field reason raises instead of rendering a fallback" do
    assert_raise KeyError, fn ->
      UserMessage.error({:invalid_input, %{kind: [:invented_reason]}})
    end
  end

  test "every field reason also has a non-generic atom message" do
    for reason <- FieldReason.all() do
      refute UserMessage.error(reason) == "The server could not complete that request."
    end
  end

  test "field reasons are not whole sentences glued after a field label" do
    assert UserMessage.field_error(:kind, :publication_not_active) ==
             "grant is no longer active; reload and choose an active one."

    assert UserMessage.error({:invalid_input, %{kind: [:publication_not_active]}}) ==
             "grant is no longer active; reload and choose an active one."
  end

  test "CommandError rejects a reason outside the closed vocabulary" do
    assert_raise ArgumentError, ~r/unknown field reason/, fn ->
      CommandError.invalid_input(%{name: [:invented_reason]})
    end
  end

  test "CommandError accepts every declared reason" do
    for reason <- FieldReason.all() do
      assert {:error, {:invalid_input, %{name: [^reason]}}} =
               CommandError.invalid_input(%{name: [reason]})
    end
  end

  test "summary leaves inline errors at their fields and retains unattached errors" do
    error = {:invalid_input, %{name: [:missing], form: [:invalid_format]}}

    assert UserMessage.summary(error, [:name]) == "form has an invalid format."
    assert UserMessage.summary(error, [:name, :form]) == nil
    assert UserMessage.summary(:name_conflict, [:name]) == "That Biot name is already in use."
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
