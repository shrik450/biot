linux? = match?({:ok, _platform}, Biot.Protocol.Platform.current())

podman? =
  case System.find_executable("podman") do
    nil -> false
    podman -> match?({_, 0}, System.cmd(podman, ["info"], stderr_to_stdout: true))
  end

excluded =
  []
  |> then(fn tags -> if System.find_executable("nix"), do: tags, else: [:nix | tags] end)
  |> then(fn tags -> if linux?, do: tags, else: [:linux | tags] end)
  |> then(fn tags -> if podman?, do: tags, else: [:podman | tags] end)

ExUnit.start(exclude: excluded)
