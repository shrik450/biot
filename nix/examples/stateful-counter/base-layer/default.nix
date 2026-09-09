{ pkgs, ... }:

{
  biot.packages = [ pkgs.curl ];
  biot.environment.BIOT_EXAMPLE = "stateful-counter";
  biot.files."example/message".text = "State survives a container restart.\n";
}
