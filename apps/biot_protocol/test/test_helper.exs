ExUnit.start()

defmodule Biot.Protocol.TestGenerators do
  import ExUnitProperties
  import StreamData

  alias Biot.Protocol.Digest
  alias Biot.Protocol.Hostname
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.Port
  alias Biot.Protocol.RelativeDirectory
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector

  def canonical_uuid do
    gen all(
          first <- hex_text(8),
          second <- hex_text(4),
          version_tail <- hex_text(3),
          variant <- member_of(~w(8 9 a b)),
          variant_tail <- hex_text(3),
          last <- hex_text(12)
        ) do
      Enum.join([first, second, "4" <> version_tail, variant <> variant_tail, last], "-")
    end
  end

  def digest do
    map(binary(length: 32), fn bytes ->
      {:ok, digest} = Digest.parse(Base.encode16(bytes, case: :lower))
      digest
    end)
  end

  def hostname do
    map(alphanumeric_text(1, 63), fn text ->
      {:ok, hostname} = Hostname.parse(text)
      hostname
    end)
  end

  def port do
    map(integer(1..65_535), fn number ->
      {:ok, port} = Port.parse(number)
      port
    end)
  end

  def relative_directory do
    map(list_of(alphanumeric_text(1, 12), min_length: 1, max_length: 5), fn segments ->
      {:ok, directory} = RelativeDirectory.parse(Enum.join(segments, "/"))
      directory
    end)
  end

  def repository_source do
    gen all(
          kind <- member_of([:https, :ssh, :scp]),
          host <- alphanumeric_text(1, 12),
          path <- list_of(alphanumeric_text(1, 12), min_length: 1, max_length: 4)
        ) do
      joined_path = Enum.join(path, "/")

      url =
        case kind do
          :https -> "https://#{host}.example/#{joined_path}.git"
          :ssh -> "ssh://git@#{host}.example/#{joined_path}.git"
          :scp -> "git@#{host}.example:#{joined_path}.git"
        end

      {:ok, repository} = RepositorySource.parse(url)
      repository
    end
  end

  def source_selector do
    one_of([
      constant(SourceSelector.nixpkgs()),
      gen all(
            repository <- repository_source(),
            ref <- alphanumeric_text(1, 24)
          ) do
        {:ok, selector} = SourceSelector.new(repository, ref)
        selector
      end
    ])
  end

  def pinned_source do
    gen all(
          selector <- source_selector(),
          revision <- hex_text(40),
          nar_bytes <- binary(length: 32)
        ) do
      nar_hash = "sha256-" <> Base.encode64(nar_bytes)
      {:ok, pinned_source} = PinnedSource.pin(selector, revision, nar_hash)
      pinned_source
    end
  end

  def non_binary_term do
    one_of([
      integer(),
      float(),
      list_of(integer()),
      map_of(integer(), binary()),
      tuple({integer(), binary()}),
      member_of([nil, true, false, :value, [], {}, %{}])
    ])
  end

  defp alphanumeric_text(min_length, max_length) do
    list_of(member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9)),
      min_length: min_length,
      max_length: max_length
    )
    |> map(&List.to_string/1)
  end

  defp hex_text(length) do
    list_of(member_of(String.graphemes("0123456789abcdef")), length: length)
    |> map(&Enum.join/1)
  end
end
