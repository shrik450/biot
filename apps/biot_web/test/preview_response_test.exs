defmodule BiotWeb.PreviewResponseTest do
  use ExUnit.Case, async: true

  alias BiotWeb.Preview.Response

  test "counts every response-head byte against one cumulative budget" do
    head = response_head([{"x-a", "1"}, {"x-b", "2"}, {"x-c", "3"}, {"x-d", "4"}])

    assert {:ok, %Response{}, "body"} = Response.parse_head(head <> "body", byte_size(head))

    assert Response.parse_head(head <> "body", byte_size(head) - 1) ==
             {:error, :malformed_response}
  end

  defp response_head(headers) do
    [
      "HTTP/1.1 200 OK\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]
    |> IO.iodata_to_binary()
  end
end
