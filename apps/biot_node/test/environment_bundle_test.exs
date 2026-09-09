defmodule Biot.Node.EnvironmentBundleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Node.EnvironmentBundle
  alias Biot.Node.StorePath

  @hash "0123456789abcdfghijklmnpqrsvwxyz"

  test "parse returns the four paths from format 1" do
    encoded = encoded_bundle()

    assert {:ok, bundle} = EnvironmentBundle.parse(encoded)
    assert StorePath.to_string(bundle.closure_root) == encoded["closure_root"]
    assert StorePath.to_string(bundle.entrypoint) == encoded["entrypoint"]
    assert StorePath.to_string(bundle.environment_file) == encoded["environment_file"]
    assert StorePath.to_string(bundle.config_root) == encoded["config_root"]
  end

  test "parse rejects missing and extra keys" do
    encoded = encoded_bundle()

    for key <- Map.keys(encoded) do
      assert EnvironmentBundle.parse(Map.delete(encoded, key)) == {:error, :invalid_format}
    end

    assert EnvironmentBundle.parse(Map.put(encoded, "extra", true)) ==
             {:error, :invalid_format}
  end

  test "parse distinguishes an unsupported numeric format" do
    for format <- [0, 2, 1.0, -1, 1_000_000] do
      assert EnvironmentBundle.parse(%{encoded_bundle() | "format" => format}) ==
               {:error, :unsupported_format}
    end
  end

  test "parse rejects nonnumeric formats as invalid" do
    for format <- [nil, "1", :one, %{}, []] do
      assert EnvironmentBundle.parse(%{encoded_bundle() | "format" => format}) ==
               {:error, :invalid_format}
    end
  end

  property "parse returns its declared shape for every binary" do
    check all(value <- StreamData.binary()) do
      assert_parse_result(EnvironmentBundle.parse(value))
    end
  end

  property "parse returns its declared shape for every term" do
    check all(value <- StreamData.term()) do
      assert_parse_result(EnvironmentBundle.parse(value))
    end
  end

  property "parse never raises when one valid key is removed" do
    check all(key <- StreamData.member_of(Map.keys(encoded_bundle()))) do
      encoded_bundle()
      |> Map.delete(key)
      |> EnvironmentBundle.parse()
      |> assert_parse_result()
    end
  end

  property "parse never raises when one valid value is replaced" do
    check all(
            key <- StreamData.member_of(Map.keys(encoded_bundle())),
            replacement <- StreamData.term()
          ) do
      encoded_bundle()
      |> Map.put(key, replacement)
      |> EnvironmentBundle.parse()
      |> assert_parse_result()
    end
  end

  property "parse accepts generated valid bundles" do
    check all(paths <- StreamData.list_of(store_path(), length: 4)) do
      encoded =
        encoded_bundle()
        |> Map.put("closure_root", Enum.at(paths, 0))
        |> Map.put("entrypoint", Enum.at(paths, 1))
        |> Map.put("environment_file", Enum.at(paths, 2))
        |> Map.put("config_root", Enum.at(paths, 3))

      assert {:ok, %EnvironmentBundle{}} = EnvironmentBundle.parse(encoded)
    end
  end

  defp encoded_bundle do
    %{
      "format" => 1,
      "closure_root" => "/nix/store/#{@hash}-bundle",
      "entrypoint" => "/nix/store/#{@hash}-entrypoint/bin/biot-entrypoint",
      "environment_file" => "/nix/store/#{@hash}-environment",
      "config_root" => "/nix/store/#{@hash}-config"
    }
  end

  defp store_path do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 30)
    |> StreamData.map(&("/nix/store/#{@hash}-" <> &1))
  end

  defp assert_parse_result({:ok, %EnvironmentBundle{}}), do: :ok

  defp assert_parse_result({:error, reason})
       when reason in [:invalid_format, :unsupported_format],
       do: :ok

  defp assert_parse_result(result) do
    flunk("parse returned #{inspect(result)}")
  end
end
