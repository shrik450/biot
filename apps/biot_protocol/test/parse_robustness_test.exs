defmodule Biot.Protocol.ParseRobustnessTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.TestGenerators, as: Generators

  @parsers [
    {Biot.Protocol.CanonicalUuid, [:invalid_format]},
    {Biot.Protocol.BiotId, [:invalid_format]},
    {Biot.Protocol.ConnectionId, [:invalid_format]},
    {Biot.Protocol.EnvironmentId, [:invalid_format]},
    {Biot.Protocol.IncarnationId, [:invalid_format]},
    {Biot.Protocol.NodeId, [:invalid_format]},
    {Biot.Protocol.OperationId, [:invalid_format]},
    {Biot.Protocol.PrincipalId, [:invalid_format]},
    {Biot.Protocol.PrivateDiagnosticId, [:invalid_format]},
    {Biot.Protocol.RegistrationId, [:invalid_format]},
    {Biot.Protocol.Digest, [:invalid_format]},
    {Biot.Protocol.Hostname, [:invalid_format]},
    {Biot.Protocol.BiotName, [:invalid_format]},
    {Biot.Protocol.Port, [:invalid_format, :out_of_range]},
    {Biot.Protocol.RepositorySource,
     [:invalid_format, :embedded_credentials, :repository_url_too_long]},
    {Biot.Protocol.SourceSelector,
     [:invalid_format, :embedded_credentials, :repository_url_too_long, :source_ref_too_long]},
    {Biot.Protocol.PinnedSource, [:invalid_format, :embedded_credentials]}
  ]

  property "every parser handles arbitrary binaries without raising" do
    check all(value <- StreamData.binary()) do
      for {module, reasons} <- @parsers do
        assert_parse_result(module, value, reasons)
      end
    end
  end

  property "every parser handles arbitrary non-binary terms without raising" do
    check all(value <- Generators.non_binary_term()) do
      for {module, reasons} <- @parsers do
        assert_parse_result(module, value, reasons)
      end
    end
  end

  defp assert_parse_result(module, value, reasons) do
    case module.parse(value) do
      {:ok, _parsed} ->
        :ok

      {:error, reason} when is_atom(reason) ->
        assert reason in reasons,
               "#{inspect(module)} returned undeclared reason #{inspect(reason)} for #{inspect(value)}"

      result ->
        flunk(
          "#{inspect(module)} returned invalid result #{inspect(result)} for #{inspect(value)}"
        )
    end
  end
end
