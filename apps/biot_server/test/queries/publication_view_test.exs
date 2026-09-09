defmodule Biot.Server.Queries.PublicationViewTest do
  use ExUnit.Case, async: true

  alias Biot.Server.Queries.PublicationView
  alias Biot.Server.Schema.Publication
  alias Biot.Server.TestFixtures

  setup do
    low = publication(3_000, 1)
    high = publication(8_080, 2)

    %{low: low, high: high, publications: [low, high]}
  end

  test "the owner sees every publication", context do
    assert PublicationView.visible(context.publications, :owner) == context.publications
  end

  test "a collaborator sees only the ports in their view grants", context do
    role = {:collaborator, %{shell: true, view_ports: [context.high.port]}}

    assert PublicationView.visible(context.publications, role) == [context.high]
  end

  test "a collaborator with no view grants sees nothing", context do
    role = {:collaborator, %{shell: true, view_ports: []}}

    assert PublicationView.visible(context.publications, role) == []
  end

  test "a view grant for an unpublished port shows nothing", context do
    role = {:collaborator, %{shell: false, view_ports: [TestFixtures.port(9_999)]}}

    assert PublicationView.visible(context.publications, role) == []
  end

  test "a collaborator granted every port sees every publication", context do
    role =
      {:collaborator, %{shell: false, view_ports: [context.low.port, context.high.port]}}

    assert PublicationView.visible(context.publications, role) == context.publications
  end

  test "project builds configured HTTPS URLs and sorts them by port", context do
    assert PublicationView.project(
             [context.high, context.low],
             "preview.example.test"
           ) == [
             %{port: TestFixtures.port(3_000), url: "https://preview-1.preview.example.test"},
             %{port: TestFixtures.port(8_080), url: "https://preview-2.preview.example.test"}
           ]
  end

  test "project preserves an empty publication list" do
    assert PublicationView.project([], "preview.example.test") == []
  end

  defp publication(port, hostname) do
    %Publication{
      port: TestFixtures.port(port),
      hostname: TestFixtures.hostname(hostname),
      state: :active
    }
  end
end
