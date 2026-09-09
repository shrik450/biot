defmodule Biot.Server.Queries.PublicationViewTest do
  use ExUnit.Case, async: true

  alias Biot.Server.Queries.PublicationView
  alias Biot.Server.Schema.Publication
  alias Biot.Server.TestFixtures

  test "project builds configured HTTPS URLs and sorts them by port" do
    publications = [
      %Publication{port: TestFixtures.port(8_080), hostname: TestFixtures.hostname(2)},
      %Publication{port: TestFixtures.port(3_000), hostname: TestFixtures.hostname(1)}
    ]

    assert PublicationView.project(publications, "preview.example.test") == [
             %{port: TestFixtures.port(3_000), url: "https://preview-1.preview.example.test"},
             %{port: TestFixtures.port(8_080), url: "https://preview-2.preview.example.test"}
           ]
  end

  test "project preserves an empty publication list" do
    assert PublicationView.project([], "preview.example.test") == []
  end
end
