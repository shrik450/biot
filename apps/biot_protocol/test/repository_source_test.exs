defmodule Biot.Protocol.RepositorySourceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.TestGenerators, as: Generators

  property "repository sources round-trip without changing their URL" do
    check all(repository <- Generators.repository_source()) do
      assert RepositorySource.parse(RepositorySource.to_string(repository)) == {:ok, repository}
      assert Kernel.to_string(repository) == RepositorySource.to_string(repository)
    end
  end

  test "parse accepts supported credential-free repository forms" do
    valid_urls = [
      "https://github.com/example/project.git",
      "ssh://git@github.com/example/project.git",
      "git@github.com:example/project.git"
    ]

    for url <- valid_urls do
      assert {:ok, repository} = RepositorySource.parse(url)
      assert RepositorySource.to_string(repository) == url
    end
  end

  test "parse rejects embedded HTTPS credentials" do
    for url <- [
          "https://user@github.com/example/project.git",
          "https://user:secret@github.com/example/project.git",
          "https://user%3Asecret@github.com/example/project.git"
        ] do
      assert RepositorySource.parse(url) == {:error, :embedded_credentials}
    end
  end

  test "parse permits an SSH user but rejects an SSH password" do
    assert {:ok, _repository} =
             RepositorySource.parse("ssh://git@github.com/example/project.git")

    assert RepositorySource.parse("ssh://git:secret@github.com/example/project.git") ==
             {:error, :embedded_credentials}

    assert RepositorySource.parse("ssh://git%3Asecret@github.com/example/project.git") ==
             {:error, :embedded_credentials}
  end

  test "parse rejects fragments, queries, whitespace, and incomplete URLs" do
    invalid_urls = [
      "https://github.com/example/project.git#main",
      "https://github.com/example/project.git?ref=main",
      "https://github.com",
      "https:///example/project.git",
      "git://github.com/example/project.git",
      "git@github.com:",
      "github.com/example/project.git",
      "https://github.com/example/my project.git",
      "https://github.com/example/project.git\n"
    ]

    for url <- invalid_urls do
      assert RepositorySource.parse(url) == {:error, :invalid_format}
    end
  end
end
