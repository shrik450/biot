ExUnit.start()

defmodule Biot.Protocol.TestGenerators do
  import ExUnitProperties
  import StreamData

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.Digest
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.Failure
  alias Biot.Protocol.Hostname
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.Platform
  alias Biot.Protocol.Port
  alias Biot.Protocol.PrivateDiagnosticId
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector

  @failure_stages ~w(node allocate initialize resolve prepare install start retire release_environment remove_data release_allocation inspect)a
  @failure_codes ~w(node_abandoned resource_unavailable invalid_source resolution_failed preparation_failed installation_failed invalid_configuration container_failed lost_data ownership_mismatch inspection_failed)a
  @failure_retries ~w(automatic after_change operator)a

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

  def repository_source do
    gen all(
          host <- alphanumeric_text(1, 12),
          path <- list_of(alphanumeric_text(1, 12), min_length: 1, max_length: 4)
        ) do
      joined_path = Enum.join(path, "/")
      url = "https://#{host}.example/#{joined_path}.git"

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

  def biot_id, do: identifier(BiotId)
  def connection_id, do: identifier(ConnectionId)
  def environment_id, do: identifier(EnvironmentId)

  def incarnation_id do
    map(binary(length: 32), fn bytes ->
      {:ok, id} = IncarnationId.parse(Base.encode16(bytes, case: :lower))
      id
    end)
  end

  def private_diagnostic_id, do: identifier(PrivateDiagnosticId)

  def identifier(module) do
    map(canonical_uuid(), fn value ->
      {:ok, id} = module.parse(value)
      id
    end)
  end

  def container_state do
    one_of([constant(:starting), constant(:running), map(non_negative_integer(), &{:exited, &1})])
  end

  @spec failure_stages() :: [atom()]
  def failure_stages, do: @failure_stages

  @spec failure_codes() :: [atom()]
  def failure_codes, do: @failure_codes

  def failure do
    gen all(
          stage <- member_of(@failure_stages),
          code <- member_of(@failure_codes),
          retry_policy <- member_of(@failure_retries),
          message <- string(:printable, max_length: 100),
          diagnostic_ref <- one_of([constant(nil), private_diagnostic_id()])
        ) do
      %Failure{
        stage: stage,
        code: code,
        retry: retry_policy,
        message: message,
        diagnostic_ref: diagnostic_ref
      }
    end
  end

  def platform do
    map(member_of(["x86_64-linux", "aarch64-linux"]), fn text ->
      {:ok, platform} = Platform.parse(text)
      platform
    end)
  end

  def manifest do
    gen all(
          platform <- platform(),
          base_nixpkgs <- pinned_source(),
          layers <- list_of(pinned_source(), max_length: 4)
        ) do
      Manifest.build(platform, base_nixpkgs, layers)
    end
  end

  def environment_selection do
    gen all(
          base_nixpkgs <- source_selector(),
          layers <- list_of(source_selector(), max_length: 4)
        ) do
      %EnvironmentSelection{base_nixpkgs: base_nixpkgs, layers: layers}
    end
  end

  def desired do
    gen all(
          revision <- positive_integer(),
          state <- member_of(Desired.states()),
          environment_id <- environment_id()
        ) do
      %Desired{revision: revision, state: state, environment_id: environment_id}
    end
  end

  def execution_spec do
    gen all(
          biot_id <- biot_id(),
          repository <- repository_source(),
          desired <- desired(),
          selection <- environment_selection()
        ) do
      %ExecutionSpec{
        biot_id: biot_id,
        repository: repository,
        desired: desired,
        environment: %{id: desired.environment_id, selection: selection}
      }
    end
  end

  def biot_spec do
    gen all(execution <- execution_spec(), access_revision <- positive_integer()) do
      %BiotSpec{execution: execution, access_revision: access_revision}
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
