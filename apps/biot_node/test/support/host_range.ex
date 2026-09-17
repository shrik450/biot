defmodule Biot.Node.TestHostRange do
  @moduledoc """
  The host's subordinate UID/GID range for the account running the suite.

  The node's logical UID range is the host's subordinate range: `Podman.grant/3` maps each
  allocation's offset through the service account's user namespace, and
  `Agent.peer_in_range?/2` compares the connect peer's host UID against the same range. The tests
  used to hardcode `100_000`, which is the privileged Linux host image's range; a host whose range
  starts elsewhere (Fedora starts at 524288) fails every ownership assertion. Read it instead.
  """

  @spec subordinate_ids() :: {non_neg_integer(), pos_integer()}
  def subordinate_ids do
    user = System.cmd("id", ["-un"]) |> elem(0) |> String.trim()
    entry(user) || {100_000, 65_536}
  end

  defp entry(user) do
    ["/etc/subuid", "/etc/subgid"]
    |> Enum.find_value(fn path ->
      case File.read(path) do
        {:ok, contents} -> find_user(contents, user)
        _unreadable -> nil
      end
    end)
  end

  defp find_user(contents, user) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.find_value(&user_entry(&1, user))
  end

  defp user_entry(line, user) do
    case String.split(line, ":") do
      [^user, start, count] -> {String.to_integer(start), String.to_integer(count)}
      _unrelated -> nil
    end
  end
end
