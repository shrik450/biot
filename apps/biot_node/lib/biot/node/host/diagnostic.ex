defmodule Biot.Node.Host.Diagnostic do
  @moduledoc "Builds a diagnostic from host command output."

  alias Biot.Node.Diagnostic
  alias Biot.Node.Host.Command

  @spec from_command(Command.Result.t()) :: Diagnostic.t()
  def from_command(%Command.Result{stderr: "", stdout: stdout, stdout_truncated: truncated}),
    do: {stdout, truncated}

  def from_command(%Command.Result{stderr: stderr, stderr_truncated: truncated}),
    do: {stderr, truncated}
end
