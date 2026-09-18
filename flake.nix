{
  description = "Biot development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      devShells = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          beam = pkgs.beam28Packages;
        in
        {
          default = pkgs.mkShell {
            packages = [
              beam.erlang
              beam.elixir_1_20
              beam.hex
              beam.rebar3
              pkgs.go_1_26
            ];

            shellHook = ''
              # The BEAM reads the locale to pick its filename encoding. Without a UTF-8 locale it
              # falls back to latin1 and Elixir warns on every start.
              export LANG=C.UTF-8
            '';
          };
        }
      );
    };
}
