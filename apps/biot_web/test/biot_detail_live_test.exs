defmodule BiotWeb.BiotDetailLiveTest do
  use BiotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Ecto.Query

  alias Biot.Protocol.Hostname
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Publication, ShellGrant, ViewGrant}
  alias Biot.Server.Sessions
  alias BiotWeb.Live.BiotTabs
  alias BiotWeb.TestFixtures

  test "the owner detail renders lifecycle actions and route-backed tabs" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1, desired_state: :stopped)
    {:ok, token} = Sessions.start_control(owner.id)

    {:ok, view, _html} = live(authenticated_conn(token), "/biots/#{biot.id}")
    html = render(view)

    assert html =~ to_string(biot.name)
    assert html =~ "desired stopped"
    assert html =~ ">start<"
    assert html =~ ">rebuild<"
    assert html =~ ">destroy<"
    assert html =~ "publications"
    assert html =~ "access"
    assert html =~ "secrets"
    assert html =~ "logs"
    assert html =~ "/biots/#{biot.id}/publications"
  end

  test "a shell collaborator sees only permitted detail tabs and cannot mutate lifecycle" do
    owner = TestFixtures.principal(1)
    collaborator = TestFixtures.principal(2)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    Repo.insert!(%ShellGrant{biot_id: biot.id, principal_id: collaborator.id})
    {:ok, token} = Sessions.start_control(collaborator.id)

    {:ok, view, _html} = live(authenticated_conn(token), "/biots/#{biot.id}/access")
    html = render(view)

    refute html =~ ">access<"
    refute html =~ ">secrets<"
    refute html =~ ~s(phx-click="start")
    refute html =~ ~s(phx-click="stop")
    refute html =~ ~s(phx-click="rebuild")
    refute html =~ ~s(phx-click="destroy")
    assert html =~ ">logs<"
    assert html =~ "this section is not available for your role"

    before = Repo.get!(Biot.Server.Schema.Biot, biot.id).desired_revision
    render_click(view, "stop")
    after_attempt = Repo.get!(Biot.Server.Schema.Biot, biot.id).desired_revision
    assert after_attempt == before
  end

  test "a stale lifecycle revision reloads the detail and explains the conflict" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    {:ok, token} = Sessions.start_control(owner.id)

    {:ok, view, _html} = live(authenticated_conn(token), "/biots/#{biot.id}")
    assert render(view) =~ to_string(biot.name)

    Repo.update_all(
      from(biot_row in Biot.Server.Schema.Biot, where: biot_row.id == ^biot.id),
      set: [desired_revision: 2]
    )

    html = render_click(view, "stop")
    assert html =~ "This Biot changed; its current revision is 2. Reload and try again."
    assert html =~ "<dd>2</dd>"
  end

  test "view collaborators can render only the publication they were granted" do
    owner = TestFixtures.principal(1)
    viewer = TestFixtures.principal(2)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    {:ok, hostname_a} = Hostname.parse("alpha-preview")
    {:ok, hostname_b} = Hostname.parse("beta-preview")
    port_a = TestFixtures.port(3000)
    port_b = TestFixtures.port(4000)

    for {port, hostname} <- [{port_a, hostname_a}, {port_b, hostname_b}] do
      Repo.insert!(%Publication{biot_id: biot.id, port: port, hostname: hostname, state: :active})
    end

    Repo.insert!(%ViewGrant{biot_id: biot.id, port: port_a, principal_id: viewer.id})
    {:ok, token} = Sessions.start_control(viewer.id)

    {:ok, view, _html} = live(authenticated_conn(token), "/biots/#{biot.id}/publications")
    html = render(view)

    assert html =~ "alpha-preview.env.test"
    refute html =~ "beta-preview.env.test"
    refute html =~ "publication-form"
    refute html =~ ~s(phx-click="start")
    refute html =~ ~s(phx-click="stop")
    refute html =~ ~s(phx-click="rebuild")
    refute html =~ ~s(phx-click="destroy")

    before = Repo.get!(Biot.Server.Schema.Biot, biot.id).desired_revision
    render_click(view, "stop")
    assert Repo.get!(Biot.Server.Schema.Biot, biot.id).desired_revision == before
  end

  test "tab vocabulary and visibility agree with projected roles" do
    owner = %{role: :owner}
    shell = %{role: {:collaborator, %{shell: true, view_ports: []}}}
    viewer = %{role: {:collaborator, %{shell: false, view_ports: [TestFixtures.port(3000)]}}}

    assert BiotTabs.from_action(nil) == :overview
    assert BiotTabs.from_action(:logs) == :logs
    assert BiotTabs.from_action(:unknown) == :overview
    assert BiotTabs.visible?(owner, :access)
    assert BiotTabs.visible?(owner, :secrets)
    assert BiotTabs.visible?(shell, :logs)
    refute BiotTabs.visible?(shell, :access)
    refute BiotTabs.visible?(viewer, :logs)
    assert BiotTabs.visible?(viewer, :publications)
  end

  defp authenticated_conn(token),
    do: Plug.Test.init_test_session(build_conn(), %{"token" => token})
end
