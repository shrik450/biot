defmodule Biot.Node.Host.Podman do
  @moduledoc "Runs Podman commands and recognizes when a named resource is absent."

  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Diagnostic, as: HostDiagnostic
  alias Biot.Node.Host.Paths

  @type resource :: :container | :network

  @spec run(Config.t(), [String.t()]) ::
          {:ok, Command.Result.t()} | {:error, :executable_not_found | :setsid_not_found | term()}
  def run(config, arguments) do
    Command.run(
      config.setsid_executable,
      Config.capture_tools(config),
      config.podman_executable,
      ["--module", Paths.podman_config(config) | arguments],
      timeout_ms: config.command_timeout_ms,
      max_output_bytes: config.command_max_output_bytes,
      max_stderr_bytes: config.command_max_stderr_bytes
    )
  end

  @doc "Starts a Podman command the caller reads itself, such as the container event stream."
  @spec open(Config.t(), [String.t()]) ::
          {:ok, Command.Stream.t()} | {:error, :executable_not_found | :setsid_not_found | term()}
  def open(config, arguments) do
    Command.open(
      config.setsid_executable,
      Config.capture_tools(config),
      config.podman_executable,
      ["--module", Paths.podman_config(config) | arguments],
      timeout_ms: config.command_timeout_ms,
      max_stderr_bytes: config.command_max_stderr_bytes
    )
  end

  @doc "Starts a Podman command with both output streams sent to the caller."
  @spec open_combined(Config.t(), [String.t()]) ::
          {:ok, Command.Stream.t()} | {:error, :executable_not_found | :setsid_not_found | term()}
  def open_combined(config, arguments) do
    Command.open(
      config.setsid_executable,
      Config.capture_tools(config),
      "/bin/sh",
      [
        "-c",
        "exec \"$@\" 2>&1",
        "biot-podman",
        config.podman_executable,
        "--module",
        Paths.podman_config(config)
        | arguments
      ],
      timeout_ms: config.command_timeout_ms,
      max_stderr_bytes: config.command_max_stderr_bytes
    )
  end

  @spec absent?(resource(), Command.Result.t()) :: boolean()
  def absent?(resource, result) do
    {content, _truncated} = HostDiagnostic.from_command(result)
    diagnostic = String.downcase(content)

    # Podman exposes absence through unstable diagnostic prose instead of a distinct exit status.
    Enum.any?(absence_phrases(resource), &String.contains?(diagnostic, &1))
  end

  defp absence_phrases(:container) do
    ["no such container", "no such object", "no container with name or id", "not found"]
  end

  defp absence_phrases(:network), do: ["no such network", "not found"]
end
