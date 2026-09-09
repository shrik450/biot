defmodule Biot.Protocol.PinnedSource do
  @moduledoc ~S|A resolved source with a commit revision and Nix NAR hash. Canonical form is "nixpkgs#<rev>#<nar_hash>" or "<url>#<rev>#<nar_hash>".|

  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector

  @enforce_keys [:source]
  defstruct [:source]

  @type source ::
          {:nixpkgs, String.t(), String.t()}
          | {:git, RepositorySource.t(), String.t(), String.t()}
  @type t :: %__MODULE__{source: source()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format | :embedded_credentials}
  def parse(value) when is_binary(value) do
    case String.split(value, "#") do
      [url, revision, nar_hash] ->
        with {:ok, source} <- parse_source(url) do
          build(source, revision, nar_hash)
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec pin(SourceSelector.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, :invalid_format | :embedded_credentials}
  def pin(%SourceSelector{source: :nixpkgs}, revision, nar_hash) do
    build(:nixpkgs, revision, nar_hash)
  end

  def pin(%SourceSelector{source: {:git, repository, _ref}}, revision, nar_hash) do
    build({:git, repository}, revision, nar_hash)
  end

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{source: {:nixpkgs, revision, nar_hash}}) do
    Enum.join(["nixpkgs", revision, nar_hash], "#")
  end

  def to_string(%__MODULE__{source: {:git, repository, revision, nar_hash}}) do
    Enum.join([RepositorySource.to_string(repository), revision, nar_hash], "#")
  end

  @spec canonical_fields(t()) :: iodata()
  def canonical_fields(%__MODULE__{source: {:nixpkgs, revision, nar_hash}}) do
    [<<0>>, encode_field(revision), encode_field(nar_hash)]
  end

  def canonical_fields(%__MODULE__{
        source: {:git, %RepositorySource{url: url}, revision, nar_hash}
      }) do
    [<<1>>, encode_field(url), encode_field(revision), encode_field(nar_hash)]
  end

  defp parse_source("nixpkgs"), do: {:ok, :nixpkgs}

  defp parse_source(value) when is_binary(value) do
    with {:ok, repository} <- RepositorySource.parse(value) do
      {:ok, {:git, repository}}
    end
  end

  defp parse_source(_value), do: {:error, :invalid_format}

  defp build(source, revision, nar_hash) do
    with {:ok, revision} <- parse_revision(revision),
         {:ok, nar_hash} <- parse_nar_hash(nar_hash) do
      {:ok, %__MODULE__{source: pin_source(source, revision, nar_hash)}}
    end
  end

  defp pin_source(:nixpkgs, revision, nar_hash), do: {:nixpkgs, revision, nar_hash}

  defp pin_source({:git, repository}, revision, nar_hash),
    do: {:git, repository, revision, nar_hash}

  defp encode_field(value) when is_binary(value) do
    [<<byte_size(value)::unsigned-big-32>>, value]
  end

  defp parse_revision(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, value) do
      {:ok, value}
    else
      {:error, :invalid_format}
    end
  end

  defp parse_revision(_value), do: {:error, :invalid_format}

  defp parse_nar_hash(value) when is_binary(value) do
    with "sha256-" <> encoded <- value,
         {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) == 32,
         ^value <- "sha256-" <> Base.encode64(bytes) do
      {:ok, value}
    else
      _ -> {:error, :invalid_format}
    end
  end

  defp parse_nar_hash(_value), do: {:error, :invalid_format}
end

defimpl String.Chars, for: Biot.Protocol.PinnedSource do
  def to_string(value), do: Biot.Protocol.PinnedSource.to_string(value)
end
