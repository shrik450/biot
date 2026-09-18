defmodule Biot.Node.TestSandboxGate do
  @moduledoc false

  alias Biot.Node.Host.{Config, Setup}

  # The host tests call `Biot.Node.Host.Setup.start_link/1` in `setup_all` and need it to report
  # `:ignore`, so the gate calls the same function with the same settings. Anything cheaper is an
  # approximation of the capability, and `unshare -U` in particular succeeds on a machine where the
  # sandboxed build then fails to remount /proc.
  @spec supported?() :: :ok | {:error, term()}
  def supported? do
    data_root =
      BiotTest.Temp.directory("biot-sandbox-gate")

    settings = [
      data_root: data_root,
      uid_range_base: 100_000,
      uid_range_count: 1_024,
      uid_range_limit: 165_536
    ]

    previous =
      Map.new(settings, fn {key, _value} -> {key, Application.get_env(:biot_node, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:biot_node, key, value) end)

    try do
      case Setup.start_link([]) do
        :ignore -> :ok
        {:error, reason} -> {:error, reason}
      end
    after
      :persistent_term.erase(Config)
      Enum.each(previous, fn {key, value} -> Application.put_env(:biot_node, key, value) end)
      File.rm_rf(data_root)
    end
  end

  @spec message(term()) :: String.t()
  def message({:error, reason}), do: render_message(reason)

  defp render_message(reason) do
    """
    The Biot node host tests are skipped because this machine cannot sandbox a Nix build in a
    container.

    They need a rootless Podman container that can create a nested user and PID namespace and mount
    a fresh /proc, which is what a sandboxed Nix build does. Podman is installed here, but the check
    the node runs at boot reported:

    #{diagnostic(reason)}

    The repository is fine; this machine is missing the capability. Run these tests in the project's
    privileged Linux host image instead:

        docker build -t biot-linux-host docker/linux-host
        docker/linux-host/run-tests.sh

    """
  end

  defp diagnostic({:build_sandboxing_unsupported, detail}) when is_binary(detail) do
    lines = detail |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

    line = Enum.find(Enum.reverse(lines), List.last(lines), &String.starts_with?(&1, "error:"))

    "      " <> (line || "(no diagnostic was captured)")
  end

  defp diagnostic(reason), do: "      " <> inspect(reason)
end

linux? = match?({:ok, _platform}, Biot.Protocol.Platform.current())

podman? =
  case System.find_executable("podman") do
    nil -> false
    podman -> match?({_, 0}, System.cmd(podman, ["info"], stderr_to_stdout: true))
  end

# `podman info` says podman is installed, which is not the capability the host tests need. Ask the
# node's own startup check instead of a proxy, so a host that cannot sandbox excludes these tests
# loudly rather than failing them in `setup_all` with a Nix error.
sandboxing =
  if linux? and podman? do
    Biot.Node.TestSandboxGate.supported?()
  else
    :not_checked
  end

exclude_podman? = not (linux? and podman? and sandboxing == :ok)

excluded =
  []
  |> then(fn tags -> if System.find_executable("nix"), do: tags, else: [:nix | tags] end)
  |> then(fn tags -> if linux?, do: tags, else: [:linux | tags] end)
  |> then(fn tags -> if exclude_podman?, do: [:podman | tags], else: tags end)

if linux? and podman? and sandboxing != :ok do
  IO.puts(:stderr, Biot.Node.TestSandboxGate.message(sandboxing))
end

ExUnit.start(exclude: excluded)
