defmodule BiotWeb.ApiContractTest do
  use ExUnit.Case, async: true

  alias BiotWeb.Api.BearerHeader
  alias BiotWeb.Api.ErrorResponse
  alias BiotWeb.Api.Response

  describe "BearerHeader" do
    test "accepts one case-insensitive bearer token" do
      assert BearerHeader.token(["Bearer biot_abc-._~+/="]) ==
               {:ok, "biot_abc-._~+/="}

      assert BearerHeader.token(["bEaReR biot_token"]) == {:ok, "biot_token"}
    end

    test "rejects absent, repeated, malformed, and blank credentials" do
      for headers <- [
            [],
            ["Bearer one", "Bearer two"],
            ["Basic biot_token"],
            ["Bearer"],
            ["Bearer  "]
          ] do
        assert BearerHeader.token(headers) == :error, inspect(headers)
      end
    end
  end

  describe "ErrorResponse" do
    test "matches the model status table" do
      for {error, status} <- [
            {:unauthenticated, 401},
            {:forbidden, 403},
            {:not_found, 404},
            {{:invalid_input, %{name: [:missing], port: [:out_of_range]}}, 422},
            {{:revision_conflict, 9}, 409},
            {:destroyed, 409},
            {:creation_conflict, 409},
            {:name_conflict, 409},
            {:hostname_conflict, 409},
            {:node_disabled, 409},
            {:node_abandoned, 409},
            {:capacity_exceeded, 409},
            {:temporarily_unavailable, 503}
          ] do
        {^status, body} = ErrorResponse.build(error)
        assert body["error"] == error_tag(error)
      end
    end

    test "flattens invalid input and revision details" do
      assert {422, %{"error" => "invalid_input", "fields" => %{"id" => ["invalid_format"]}}} =
               ErrorResponse.build({:invalid_input, %{id: [:invalid_format]}})

      assert ErrorResponse.build({:revision_conflict, 4}) ==
               {409, %{"error" => "revision_conflict", "current_revision" => 4}}
    end
  end

  describe "Response" do
    test "returns an empty 204 response for bare effects" do
      assert Response.build(:ok) == {204, [], nil}
    end
  end

  defp error_tag({:invalid_input, _}), do: "invalid_input"
  defp error_tag({:revision_conflict, _}), do: "revision_conflict"
  defp error_tag(error), do: Atom.to_string(error)
end
