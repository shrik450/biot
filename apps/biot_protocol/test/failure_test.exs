defmodule Biot.Protocol.FailureTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Biot.Protocol.Failure
  alias Biot.Protocol.TestGenerators, as: Generators

  @retries ~w(automatic after_change operator)a

  test "every stage, code, and retry policy the node can report round-trips" do
    for stage <- Generators.failure_stages(),
        code <- Generators.failure_codes(),
        retry_policy <- @retries do
      failure = %Failure{
        stage: stage,
        code: code,
        retry: retry_policy,
        message: "reported",
        diagnostic_ref: nil
      }

      assert Failure.parse(Failure.encode(failure)) == {:ok, failure},
             "#{stage}/#{code}/#{retry_policy} did not round-trip"
    end
  end

  test "the stages the node's own lifecycle actions name are all known" do
    node_stages =
      ~w(allocate initialize resolve prepare install start retire release_environment remove_data release_allocation)a

    for stage <- node_stages do
      assert stage in Generators.failure_stages()
    end
  end

  test "the codes the node's retry classification produces are all known" do
    node_codes =
      ~w(resource_unavailable container_failed invalid_source resolution_failed preparation_failed invalid_configuration lost_data ownership_mismatch)a

    for code <- node_codes do
      assert code in Generators.failure_codes()
    end
  end

  test "an unknown stage or code is rejected rather than parsed into an atom" do
    encoded =
      Failure.encode(%Failure{
        stage: :install,
        code: :container_failed,
        retry: :automatic,
        message: "reported",
        diagnostic_ref: nil
      })

    assert Failure.parse(%{encoded | "stage" => "reticulate"}) == {:error, :invalid_format}
    assert Failure.parse(%{encoded | "code" => "gremlins"}) == {:error, :invalid_format}
    assert Failure.parse(%{encoded | "retry" => "sometimes"}) == {:error, :invalid_format}
  end
end
