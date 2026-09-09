excluded = if System.find_executable("nix"), do: [], else: [nix: true]
ExUnit.start(exclude: excluded)
