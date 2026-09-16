defmodule BiotWeb.BiotChangeLiveTest do
  use BiotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Biot.Server.CommitEffects
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Sessions
  alias BiotWeb.TestFixtures

  setup do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    {sibling, _environment} = TestFixtures.biot(owner, node, 2)
    {:ok, token} = Sessions.start_control(owner.id)

    %{biot: biot, sibling: sibling, token: token}
  end

  test "a committed external change reloads the mounted detail in place", context do
    {:ok, view, _html} = live(authenticated_conn(context.token), "/biots/#{context.biot.id}")
    assert render(view) =~ "desired running"

    Repo.update_all(
      from(biot in BiotRow, where: biot.id == ^context.biot.id),
      set: [desired_state: :stopped, desired_revision: 2]
    )

    assert :ok =
             CommitEffects.enforce(%CommitEffects{
               owners: [],
               wakes: [],
               readers: [context.biot.id]
             })

    Process.sleep(20)
    html = render(view)
    assert html =~ "desired stopped"
    assert html =~ "<dt>revision</dt><dd>2</dd>"
  end

  test "a change to a different Biot does not reload this detail", context do
    {:ok, view, _html} = live(authenticated_conn(context.token), "/biots/#{context.biot.id}")
    assert render(view) =~ "desired running"

    Repo.update_all(
      from(biot in BiotRow, where: biot.id == ^context.sibling.id),
      set: [desired_state: :stopped, desired_revision: 2]
    )

    assert :ok =
             CommitEffects.enforce(%CommitEffects{
               owners: [],
               wakes: [],
               readers: [context.sibling.id]
             })

    Process.sleep(20)
    html = render(view)
    assert html =~ "desired running"
    refute html =~ "desired stopped"
    assert html =~ "<dt>revision</dt><dd>1</dd>"
  end

  defp authenticated_conn(token),
    do: Plug.Test.init_test_session(build_conn(), %{"token" => token})
end
