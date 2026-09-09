defmodule Biot.Node.StorePathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Node.StorePath

  @hash "0123456789abcdfghijklmnpqrsvwxyz"
  @store_object "/nix/store/#{@hash}-example"
  @name_characters Enum.to_list(?0..?9) ++
                     Enum.to_list(?A..?Z) ++ Enum.to_list(?a..?z) ++ ~c"+._?=-"

  test "parse accepts a store object and paths inside it" do
    for value <- [
          @store_object,
          @store_object <> "/bin/tool",
          @store_object <> "/share/a file",
          @store_object <> "/résumé"
        ] do
      assert {:ok, path} = StorePath.parse(value)
      assert StorePath.to_string(path) == value
      assert to_string(path) == value
    end
  end

  test "parse rejects paths outside one canonical Nix store object" do
    for value <- [
          "",
          "/",
          "/nix",
          "/nix/store",
          "/nix/store/",
          "nix/store/#{@hash}-example",
          "/other/store/#{@hash}-example",
          "/nix/store/short-example",
          "/nix/store/#{String.duplicate("e", 32)}-example",
          "/nix/store/#{String.upcase(@hash)}-example",
          "/nix/store/#{@hash}-",
          "/nix/store/#{@hash}-bad:name",
          @store_object <> "/",
          @store_object <> "//bin",
          @store_object <> "/./bin",
          @store_object <> "/bin/../tool",
          @store_object <> "/" <> <<0>>
        ] do
      assert StorePath.parse(value) == {:error, :invalid_format},
             "accepted #{inspect(value)}"
    end
  end

  property "parse returns its declared shape for every binary" do
    check all(value <- StreamData.binary()) do
      assert_parse_result(StorePath.parse(value))
    end
  end

  property "parse returns its declared shape for every term" do
    check all(value <- StreamData.term()) do
      assert_parse_result(StorePath.parse(value))
    end
  end

  property "valid store paths round-trip" do
    check all(
            name <- store_name(),
            rest <-
              StreamData.list_of(
                StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
                max_length: 4
              )
          ) do
      value = Path.join(["/nix/store", @hash <> "-" <> name | rest])

      assert {:ok, path} = StorePath.parse(value)
      assert StorePath.to_string(path) == value
      assert StorePath.parse(StorePath.to_string(path)) == {:ok, path}
    end
  end

  defp store_name do
    @name_characters
    |> StreamData.member_of()
    |> StreamData.list_of(min_length: 1, max_length: 30)
    |> StreamData.map(&List.to_string/1)
  end

  defp assert_parse_result({:ok, %StorePath{}}), do: :ok
  defp assert_parse_result({:error, :invalid_format}), do: :ok

  defp assert_parse_result(result) do
    flunk("parse returned #{inspect(result)}")
  end
end
