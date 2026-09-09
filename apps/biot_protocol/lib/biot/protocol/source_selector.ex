defmodule Biot.Protocol.SourceSelector do
  @moduledoc ~S|An unpinned Nix source selected by repository and ref. Canonical form is "nixpkgs" or "<url>#<ref>".|

  alias Biot.Protocol.Limits
  alias Biot.Protocol.RepositorySource

  @enforce_keys [:source]
  defstruct [:source]

  @type source :: :nixpkgs | {:git, RepositorySource.t(), String.t()}
  @type t :: %__MODULE__{source: source()}

  @spec parse(term()) ::
          {:ok, t()}
          | {:error,
             :invalid_format
             | :embedded_credentials
             | :repository_url_too_long
             | :source_ref_too_long}
  def parse("nixpkgs"), do: {:ok, nixpkgs()}

  def parse(value) when is_binary(value) do
    case String.split(value, "#", parts: 2) do
      [url, ref] ->
        with {:ok, repository} <- RepositorySource.parse(url),
             :ok <- validate_ref(ref) do
          {:ok, %__MODULE__{source: {:git, repository, ref}}}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec new(RepositorySource.t(), String.t()) ::
          {:ok, t()} | {:error, :invalid_format | :source_ref_too_long}
  def new(%RepositorySource{} = repository, ref) do
    with :ok <- validate_ref(ref) do
      {:ok, %__MODULE__{source: {:git, repository, ref}}}
    end
  end

  @spec nixpkgs() :: t()
  def nixpkgs, do: %__MODULE__{source: :nixpkgs}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{source: :nixpkgs}), do: "nixpkgs"

  def to_string(%__MODULE__{source: {:git, repository, ref}}) do
    RepositorySource.to_string(repository) <> "#" <> ref
  end

  defp validate_ref(ref) when is_binary(ref) do
    cond do
      byte_size(ref) > Limits.max_source_ref_bytes() ->
        {:error, :source_ref_too_long}

      ref == "" or not String.valid?(ref) or Regex.match?(~r/\s/u, ref) ->
        {:error, :invalid_format}

      String.starts_with?(ref, "-") or String.contains?(ref, "..") or
          String.contains?(ref, "#") ->
        {:error, :invalid_format}

      true ->
        :ok
    end
  end

  defp validate_ref(_ref), do: {:error, :invalid_format}
end

defimpl String.Chars, for: Biot.Protocol.SourceSelector do
  def to_string(value), do: Biot.Protocol.SourceSelector.to_string(value)
end
