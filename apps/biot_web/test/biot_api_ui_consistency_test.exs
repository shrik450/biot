defmodule BiotWeb.BiotApiUiConsistencyTest do
  use BiotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Biot.Protocol.Hostname
  alias Biot.Server.Credentials
  alias Biot.Server.Credentials.Created
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Publication
  alias Biot.Server.Sessions
  alias BiotWeb.Components.Publication, as: PublicationComponent
  alias BiotWeb.TestFixtures

  test "the biot API and publication UI expose the same active publication" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    port = TestFixtures.port(3000)
    {:ok, hostname} = Hostname.parse("alpha-preview")

    Repo.insert!(%Publication{biot_id: biot.id, port: port, hostname: hostname, state: :active})

    {:ok, control_token} = Sessions.start_control(owner.id)
    {:ok, control_authentication} = Sessions.control(control_token)

    {:ok, %Created{token: bearer_token}} =
      Credentials.create(
        control_authentication,
        "consistency-test",
        DateTime.add(DateTime.utc_now(), 86_400, :second)
      )

    response = get(api_conn(bearer_token), "/api/biots/#{biot.id}")
    body = json_response(response, 200)
    publication = Enum.find(body["publications"], &(&1["port"] == 3000))

    html =
      render_component(&PublicationComponent.publication_panel/1,
        publication_state: {:loaded, [%{port: port, url: publication["url"]}]},
        owner: true,
        publish_port: "",
        enforcement: :applied,
        access_revision: body["access"]["revision"]
      )

    assert body["id"] == to_string(biot.id)
    assert body["name"] == to_string(biot.name)
    assert publication["url"] == "https://alpha-preview.env.test"
    assert html =~ publication["url"]
  end
end
