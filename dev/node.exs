defmodule Dev.Node do
  def main do
    configure()
    {:ok, _started} = Application.ensure_all_started(:biot_node)
    IO.puts("Biot node application started")
    Process.sleep(:infinity)
  end

  defp configure do
    load_release_configuration()
  end

  defp load_release_configuration do
    "../config/releases/node.exs"
    |> Path.expand(__DIR__)
    |> Config.Reader.read!()
    |> Enum.each(fn {application, values} ->
      Enum.each(values, fn {key, value} ->
        Application.put_env(application, key, value)
      end)
    end)
  end
end

Dev.Node.main()
