defmodule BiotWeb.PublicationAccessComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Queries.AccessDisplayView
  alias Biot.Server.Queries.AccessDisplayView.Grant
  alias Biot.Server.Queries.PrincipalView
  alias BiotWeb.Components.Access
  alias BiotWeb.Components.Publication
  alias BiotWeb.TestFixtures

  test "publication panel shows URLs and owner-only controls" do
    publication = %{port: TestFixtures.port(3000), url: "https://alpha.env.test"}

    owner_html =
      render_component(&Publication.publication_panel/1,
        publication_state: {:loaded, [publication]},
        owner: true,
        publish_port: "",
        enforcement: :applied,
        access_revision: 4
      )

    assert owner_html =~ "https://alpha.env.test"
    assert owner_html =~ "unpublish"
    assert owner_html =~ ~s(id="publication-form")

    collaborator_html =
      render_component(&Publication.publication_panel/1,
        publication_state: {:loaded, [publication]},
        owner: false,
        publish_port: "",
        enforcement: :applied,
        access_revision: 4
      )

    assert collaborator_html =~ "https://alpha.env.test"
    refute collaborator_html =~ "unpublish"
    refute collaborator_html =~ ~s(id="publication-form")
  end

  test "access panel renders principals and only active publication grants" do
    owner = principal(1, "Owner")
    collaborator = principal(2, "Collaborator")
    grant = %Grant{kind: {:view, TestFixtures.port(3000)}, principal: collaborator}
    access = %AccessDisplayView{owner: owner, grants: [grant]}

    html =
      render_component(&Access.access_panel/1,
        access_state: {:loaded, access},
        publications: [%{port: TestFixtures.port(3000), url: "https://alpha.env.test"}],
        share_email: "",
        share_kind: "shell",
        enforcement: :applied,
        access_revision: 5
      )

    assert html =~ "Owner"
    assert html =~ "Collaborator"
    assert html =~ "view :3000"
    assert html =~ ~s(value="view:3000")
    assert html =~ "revoke"
  end

  defp principal(number, name) do
    %PrincipalView{
      id: TestFixtures.id(PrincipalId, number),
      email: "person-#{number}@example.test",
      name: name
    }
  end
end
