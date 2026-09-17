defmodule BiotWeb.PreviewBodyTest do
  use ExUnit.Case, async: true

  alias BiotWeb.Preview.Body

  test "forwards two complete chunks supplied in one push" do
    body = Body.chunked(32)
    bytes = "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"

    assert {:done, ["abc", "de"], _body} = Body.push(body, bytes)
  end

  test "keeps chunk accounting across pushes" do
    body = Body.chunked(32)
    assert {:ok, ["ab"], body} = Body.push(body, "4\r\nab")
    assert {:done, ["cd"], _body} = Body.push(body, "cd\r\n0\r\n\r\n")
  end

  test "accepts a trailer section exactly at its bound and rejects one byte over" do
    bytes = "0\r\nx: y\r\n\r\n"

    assert {:done, [], _body} = Body.push(Body.chunked(6), bytes)
    assert Body.push(Body.chunked(5), bytes) == {:error, :trailer_too_large}
  end

  test "content-length framing accepts exactly its length and rejects extra bytes" do
    assert {:done, ["abc"], _body} = Body.push(Body.length(3), "abc")
    assert Body.push(Body.length(3), "abcd") == {:error, :unexpected_bytes}
  end
end
