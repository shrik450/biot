defmodule Mix.Tasks.Biot.Gen.Certs do
  @moduledoc "Generates minimal operator-managed certificates for Biot deployments."

  use Mix.Task

  alias Biot.Protocol.Certificates

  @shortdoc "Generates a CA, server certificate, and node certificates"

  @impl Mix.Task
  def run(args) do
    {options, positional, invalid} = OptionParser.parse(args, strict: [nodes: :integer])

    case {positional, invalid} do
      {[directory], []} -> generate(directory, Keyword.get(options, :nodes, 1))
      _other -> Mix.raise("usage: mix biot.gen.certs [--nodes N] DIRECTORY")
    end
  end

  defp generate(directory, count) when count >= 0 do
    {:ok, result} = Certificates.generate(directory, count)
    Mix.shell().info(Jason.encode!(result, pretty: true))
    Mix.shell().info("Fingerprints: #{Path.join(directory, "fingerprints.json")}")
  end

  defp generate(_directory, _count), do: Mix.raise("--nodes must be non-negative")
end
