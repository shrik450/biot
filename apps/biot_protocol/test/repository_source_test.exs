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

  test "parse accepts a credential-free HTTPS repository" do
    url = "https://github.com/example/project.git"
    assert {:ok, repository} = RepositorySource.parse(url)
    assert RepositorySource.to_string(repository) == url
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

  property "parse rejects every non-HTTPS URI scheme" do
    check all(
            scheme <-
              StreamData.one_of([
                StreamData.member_of(["http", "ssh", "git", "file", "ftp"]),
                StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
              ]),
            scheme = String.downcase(scheme),
            scheme != "https"
          ) do
      assert RepositorySource.parse("#{scheme}://example.com/project.git") ==
               {:error, :invalid_format}
    end
  end

  property "parse rejects scp-like repository addresses" do
    check all(
            user <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
            host <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
            path <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      assert RepositorySource.parse("#{user}@#{host}.example:#{path}.git") ==
               {:error, :invalid_format}
    end
  end

  test "parse rejects fragments, queries, whitespace, and incomplete URLs" do
    invalid_urls = [
      "https://github.com/example/project.git#main",
      "https://github.com/example/project.git?ref=main",
      "https://github.com",
      "https:///example/project.git",
      "git://github.com/example/project.git",
      "ssh://git@github.com/example/project.git",
      "file:///tmp/project.git",
      "/tmp/project.git",
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
