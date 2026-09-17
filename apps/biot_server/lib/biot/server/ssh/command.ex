defmodule Biot.Server.Ssh.Command do
  @moduledoc """
  Splits one SSH `exec` command line into arguments.

  Single quotes, double quotes, and backslash escapes are honored; an unterminated quote or escape,
  or an empty command, is `:invalid_command`. An explicitly quoted empty word (`""` or `''`) is an
  empty argument, not no argument. The result is what the shell entry receives, so Biot never hands
  an unparsed line to a shell.
  """

  @spec parse(String.t()) :: {:ok, [String.t()]} | {:error, :invalid_command}
  def parse(command) when is_binary(command) do
    with {:ok, arguments} <- tokenize(String.to_charlist(command), :plain, [], false, []),
         true <- arguments != [] do
      {:ok, arguments}
    else
      _invalid -> {:error, :invalid_command}
    end
  end

  def parse(_command), do: {:error, :invalid_command}

  defp tokenize([], :plain, current, started, arguments) do
    {:ok, Enum.reverse(flush(current, started, arguments))}
  end

  defp tokenize([], _mode, _current, _started, _arguments), do: {:error, :unterminated_quote}

  defp tokenize([separator | rest], :plain, current, started, arguments)
       when separator in [?\s, ?\t] do
    tokenize(rest, :plain, [], false, flush(current, started, arguments))
  end

  defp tokenize([?\\ | rest], :plain, current, _started, arguments),
    do: tokenize(rest, :escape, current, true, arguments)

  defp tokenize([?' | rest], :plain, current, _started, arguments),
    do: tokenize(rest, :single, current, true, arguments)

  defp tokenize([?" | rest], :plain, current, _started, arguments),
    do: tokenize(rest, :double, current, true, arguments)

  defp tokenize([character | rest], :plain, current, _started, arguments),
    do: tokenize(rest, :plain, [character | current], true, arguments)

  defp tokenize([?' | rest], :single, current, started, arguments),
    do: tokenize(rest, :plain, current, started, arguments)

  defp tokenize([character | rest], :single, current, started, arguments),
    do: tokenize(rest, :single, [character | current], started, arguments)

  defp tokenize([?\\ | rest], :double, current, started, arguments),
    do: tokenize(rest, :double_escape, current, started, arguments)

  defp tokenize([?" | rest], :double, current, started, arguments),
    do: tokenize(rest, :plain, current, started, arguments)

  defp tokenize([character | rest], :double, current, started, arguments),
    do: tokenize(rest, :double, [character | current], started, arguments)

  defp tokenize([character | rest], :escape, current, started, arguments),
    do: tokenize(rest, :plain, [character | current], started, arguments)

  defp tokenize([character | rest], :double_escape, current, started, arguments),
    do: tokenize(rest, :double, [character | current], started, arguments)

  defp flush(_current, false, arguments), do: arguments

  defp flush(current, true, arguments),
    do: [current |> Enum.reverse() |> List.to_string() | arguments]
end
