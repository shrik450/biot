{ pkgs }:

pkgs.buildGoModule {
  pname = "biot-agent";
  version = "1";
  src = ../agent;
  subPackages = [ "cmd/biot-agent" ];

  # The checked-in vendor tree lets every pinned nixpkgs build use the same module graph offline.
  vendorHash = null;
}
