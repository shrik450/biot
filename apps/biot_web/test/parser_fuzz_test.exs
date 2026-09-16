defmodule BiotWeb.ParserFuzzTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.{
    BiotId,
    BiotName,
    Frame,
    Hostname,
    NodeId,
    Port,
    RepositorySource,
    ShellFrame,
    ShellRequest,
    Wire
  }

  test "identifier, request, frame, and wire parsers never raise on arbitrary bytes" do
    for _ <- 1..250 do
      bytes = :crypto.strong_rand_bytes(:rand.uniform(256))

      assert_error_or_ok(BiotId.parse(bytes))
      assert_error_or_ok(BiotName.parse(bytes))
      assert_error_or_ok(Hostname.parse(bytes))
      assert_error_or_ok(NodeId.parse(bytes))
      assert_error_or_ok(Port.parse(bytes))
      assert_error_or_ok(RepositorySource.parse(bytes))
      assert_error_or_ok(ShellRequest.parse(bytes))
      assert_error_or_ok(Frame.decode(bytes, 65_536))
      assert_error_or_ok(ShellFrame.decode(bytes, :to_server))
      assert_error_or_ok(Wire.decode(bytes, 1))
    end
  end

  test "shell request and shell frames round trip their valid boundaries" do
    request = %ShellRequest{term: "xterm-256color", cols: 80, rows: 24, command: nil}
    assert {:ok, ^request} = ShellRequest.parse(ShellRequest.encode(request))

    for {frame, direction} <- [
          {{:data, "output"}, :to_server},
          {{:resize, 132, 43}, :to_agent},
          {{:exit, 17}, :to_server}
        ] do
      assert {:ok, encoded} = ShellFrame.encode(frame)
      assert {:ok, [^frame], <<>>} = ShellFrame.decode(IO.iodata_to_binary(encoded), direction)
    end
  end

  defp assert_error_or_ok({:ok, _value}), do: :ok
  defp assert_error_or_ok({:ok, _value, _rest}), do: :ok
  defp assert_error_or_ok({:error, reason}) when is_atom(reason), do: :ok
  defp assert_error_or_ok({:error, {reason, _detail}}) when is_atom(reason), do: :ok
  defp assert_error_or_ok(other), do: flunk("parser returned #{inspect(other)}")
end
