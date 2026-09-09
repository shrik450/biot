linux? = match?({:ok, _platform}, Biot.Protocol.Platform.current())

excluded =
  []
  |> then(fn tags -> if System.find_executable("nix"), do: tags, else: [:nix | tags] end)
  |> then(fn tags -> if linux?, do: tags, else: [:linux | tags] end)

ExUnit.start(exclude: excluded)
