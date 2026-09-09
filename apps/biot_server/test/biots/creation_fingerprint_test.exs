defmodule Biot.Server.Biots.CreationFingerprintTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.RelativeDirectory
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector
  alias Biot.Server.Biots.Create
  alias Biot.Server.Biots.CreationFingerprint

  @first_node_uuid "90000000-0000-4000-8000-000000000009"
  @second_node_uuid "a0000000-0000-4000-8000-00000000000a"

  test "two independently built equal commands share one fingerprint" do
    assert CreationFingerprint.compute(command()) == CreationFingerprint.compute(command())
  end

  test "changing any field of the command changes the fingerprint" do
    variants = [
      command(),
      command(name: "other-name"),
      command(repository: repository("https://github.com/example/other.git")),
      command(layers: [selector("https://github.com/example/layer.git")]),
      command(
        layers: [
          selector("https://github.com/example/layer.git"),
          selector("https://github.com/example/second.git")
        ]
      ),
      command(project_context: relative_directory("services/api")),
      command(project_context: relative_directory("services/web")),
      command(node_id: :default),
      command(node_id: node_id(@second_node_uuid))
    ]

    digests = Enum.map(variants, &CreationFingerprint.compute/1)

    assert length(Enum.uniq(digests)) == length(digests)
  end

  test "a default node and an explicit node differ" do
    explicit = command(node_id: node_id(@first_node_uuid))

    refute CreationFingerprint.compute(command(node_id: :default)) ==
             CreationFingerprint.compute(explicit)
  end

  test "field boundaries cannot be shifted between the name and the repository" do
    first = command(name: "abc", repository: repository("https://a.example/x.git"))
    second = command(name: "ab", repository: repository("https://ca.example/x.git"))

    refute CreationFingerprint.compute(first) == CreationFingerprint.compute(second)
  end

  test "the fingerprint is a raw digest of the command's fields only" do
    digest = CreationFingerprint.compute(command())

    assert byte_size(digest.value) == 32
    assert CreationFingerprint.compute(command()) == digest
  end

  defp command(opts \\ []) do
    %Create{
      name: Keyword.get(opts, :name, "worker"),
      repository:
        Keyword.get(opts, :repository, repository("https://github.com/example/project.git")),
      environment: %EnvironmentSelection{
        base_nixpkgs: SourceSelector.nixpkgs(),
        layers: Keyword.get(opts, :layers, []),
        project_context: Keyword.get(opts, :project_context)
      },
      node_id: Keyword.get(opts, :node_id, node_id(@first_node_uuid))
    }
  end

  defp repository(url) do
    {:ok, repository} = RepositorySource.parse(url)
    repository
  end

  defp selector(url) do
    {:ok, selector} = SourceSelector.new(repository(url), "main")
    selector
  end

  defp relative_directory(path) do
    {:ok, directory} = RelativeDirectory.parse(path)
    directory
  end

  defp node_id(uuid) do
    {:ok, node_id} = NodeId.parse(uuid)
    node_id
  end
end
