defmodule Biot.Protocol.StreamTarget do
  @moduledoc """
  Where one stream points inside a biot: a port, or a shell request.

  The encoded form is the agent's own request line, so the value that crosses the control link is
  the value the node sends the agent. There is one encoder, and the agent's 16 KiB line bound is
  measured from it rather than restated.
  """

  alias Biot.Protocol.Limits
  alias Biot.Protocol.Port
  alias Biot.Protocol.ShellRequest
  alias Biot.Protocol.StrictMap

  @port_fields ["target", "port"]
  @shell_fields ["target", "term", "cols", "rows", "command"]

  @type t :: {:port, Port.t()} | {:shell, ShellRequest.t()}

  @spec kind(t()) :: :port | :shell
  def kind({:port, %Port{}}), do: :port
  def kind({:shell, %ShellRequest{}}), do: :shell

  @spec encode(t()) :: map()
  def encode({:port, %Port{value: value}}), do: %{"target" => "port", "port" => value}

  def encode({:shell, %ShellRequest{} = request}) do
    Map.put(ShellRequest.encode(request), "target", "shell")
  end

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(%{"target" => "port"} = value) do
    with {:ok, value} <- StrictMap.fetch_exact(value, @port_fields),
         {:ok, port} <- Port.parse(value["port"]),
         :ok <- within_agent_line({:port, port}) do
      {:ok, {:port, port}}
    else
      _error -> {:error, :invalid_format}
    end
  end

  def parse(%{"target" => "shell"} = value) do
    with {:ok, value} <- StrictMap.fetch_exact(value, @shell_fields),
         {:ok, request} <- ShellRequest.parse(Map.delete(value, "target")),
         :ok <- within_agent_line({:shell, request}) do
      {:ok, {:shell, request}}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  # The agent reads its request line through a 16 KiB buffer including the newline, so a target
  # this side accepts must produce a line that buffer can hold.
  defp within_agent_line(target) do
    bytes =
      target
      |> encode()
      |> Jason.encode_to_iodata!()
      |> IO.iodata_length()

    if bytes + 1 <= Limits.max_agent_line_bytes(), do: :ok, else: {:error, :invalid_format}
  end
end
