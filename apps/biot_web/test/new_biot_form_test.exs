defmodule BiotWeb.NewBiotFormTest do
  use ExUnit.Case, async: true

  alias BiotWeb.Live.NewBiotForm

  test "parse reports field errors and preserves the final-state decision" do
    assert {:error, {:invalid_input, errors}} = NewBiotForm.parse(%{})
    assert errors.repository == [:missing]
    assert errors.name == [:missing]
    assert errors.environment == [:invalid_format]

    params = %{
      "repository" => "https://github.com/example/project.git",
      "name" => "demo",
      "base_source" => "nixpkgs",
      "base_ref" => "",
      "initial_state" => "running",
      "runtime_secrets" => %{"0" => %{"name" => "TOKEN", "value" => "secret"}}
    }

    assert {:ok, parsed} = NewBiotForm.parse(params)
    assert parsed.final_state == :running
    assert parsed.command.initial_state == :stopped
    assert length(parsed.runtime_secrets) == 1
  end

  test "malformed repeatable rows are rejected without raising" do
    params = %{
      "repository" => "https://github.com/example/project.git",
      "name" => "demo",
      "base_source" => "nixpkgs",
      "base_ref" => "",
      "layers" => %{"0" => :not_a_map}
    }

    assert {:error, {:invalid_input, %{environment: [:invalid_format]}}} =
             NewBiotForm.parse(params)
  end

  test "the form markup carries the unsaved-change and first-error hooks" do
    assert NewBiotForm.empty_layer(0) == %{id: 0, source: "", ref: ""}
    assert NewBiotForm.empty_runtime_secret(0) == %{id: 0, name: ""}
    assert NewBiotForm.empty_source_credential(0) == %{id: 0, source: ""}
  end

  test "fuzzing arbitrary form terms never raises" do
    for _ <- 1..200 do
      term = :crypto.strong_rand_bytes(:rand.uniform(64))
      assert match?({:error, {:invalid_input, _}}, NewBiotForm.parse(term))
    end
  end
end
