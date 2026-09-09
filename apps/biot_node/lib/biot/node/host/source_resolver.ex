defmodule Biot.Node.Host.SourceResolver do
  @moduledoc "Pins source selectors through the fixed `nix/pin.nix` boundary."

  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Outcome
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector

  @spec pin(Config.t(), SourceSelector.t()) ::
          {:ok, PinnedSource.t()} | {:error, Outcome.t()}
  def pin(config, %SourceSelector{} = selector) do
    {repository, reference} = source(config, selector)

    case command(config, repository, reference) do
      {:ok, %Command.Result{status: 0, stdout: stdout}} ->
        parse(stdout, selector)

      {:ok, %Command.Result{} = result} ->
        {:error, Outcome.from_command(:resolution_failed, result)}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp source(config, %SourceSelector{source: :nixpkgs}) do
    {config.nixpkgs_repository, config.nixpkgs_ref}
  end

  defp source(_config, %SourceSelector{source: {:git, repository, reference}}) do
    {RepositorySource.to_string(repository), reference}
  end

  defp command(config, repository, reference) do
    Command.run(
      config.setsid_executable,
      config.nix_instantiate_executable,
      [
        "--eval",
        "--strict",
        "--json",
        config.nix_pin_file,
        "--argstr",
        "url",
        repository,
        "--argstr",
        "ref",
        reference
      ],
      timeout_ms: config.command_timeout_ms,
      max_output_bytes: config.command_max_output_bytes
    )
  end

  defp parse(stdout, selector) do
    with {:ok, %{"revision" => revision, "nar_hash" => nar_hash}} <- Jason.decode(stdout),
         {:ok, pinned} <- PinnedSource.pin(selector, revision, nar_hash) do
      {:ok, pinned}
    else
      _error ->
        {:error, Outcome.new(:resolution_failed, "Nix returned invalid source JSON")}
    end
  end
end
