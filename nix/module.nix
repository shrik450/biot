{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;

  validEnvironmentName = name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null;
  validServiceName = name: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name != null;
  validRelativePath = path:
    path != ""
    && !(lib.hasPrefix "/" path)
    && builtins.all (part: part != "" && part != "." && part != "..") (lib.splitString "/" path);
  validDirectoryPath = path: path == "." || validRelativePath path;
  directoryPath = types.addCheck types.str validDirectoryPath // {
    name = "directoryPath";
    description = "a dot or a relative path with no empty, \".\", or \"..\" segment";
  };

  fileModule = {
    options.text = mkOption {
      type = types.str;
      description = "The complete contents of the immutable file.";
    };
  };

  directoryModule = {
    options = {
      root = mkOption {
        type = types.enum [ "checkout" "service_data" ];
        default = "checkout";
        description = "The private mount that contains the service directory.";
      };

      path = mkOption {
        type = directoryPath;
        default = ".";
        description = "The service directory below the selected private mount.";
      };
    };
  };

  serviceModule = {
    options = {
      command = mkOption {
        type = types.nonEmptyListOf types.str;
        description = "The executable and arguments for the service.";
      };

      directory = mkOption {
        type = types.submodule directoryModule;
        default = { };
        description = "The private directory where the service runs.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Environment variables added for this service.";
      };

      restart = mkOption {
        type = types.enum [ "always" "on-failure" "never" ];
        default = "on-failure";
        description = "When the service runner restarts this service.";
      };
    };
  };

  environmentNames = builtins.attrNames config.biot.environment;
  serviceNames = builtins.attrNames config.biot.services;
  fileNames = builtins.attrNames config.biot.files;
  serviceEnvironmentNames = lib.concatMap
    (name: builtins.attrNames config.biot.services.${name}.environment)
    serviceNames;
  reservedEnvironmentNames = [ "BIOT_CONFIG_ROOT" "HOME" "PATH" "TERM" ];
  invalidEnvironmentNames = builtins.filter
    (name: !validEnvironmentName name)
    (environmentNames ++ serviceEnvironmentNames);
  usedReservedEnvironmentNames = builtins.filter
    (name: builtins.elem name reservedEnvironmentNames)
    (environmentNames ++ serviceEnvironmentNames);
  invalidServiceNames = builtins.filter (name: !validServiceName name) serviceNames;
  invalidFileNames = builtins.filter (name: !validRelativePath name) fileNames;
in
{
  options = {
    assertions = mkOption {
      type = types.listOf types.unspecified;
      default = [ ];
      internal = true;
    };

    biot = {
      packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Packages placed on PATH for services and shells.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Environment variables shared by services and shells.";
      };

      shell = mkOption {
        type = types.package;
        default = pkgs.bash;
        description = "The default interactive shell package.";
      };

      files = mkOption {
        type = types.attrsOf (types.submodule fileModule);
        default = { };
        description = "Immutable files available below $BIOT_CONFIG_ROOT/files.";
      };

      services = mkOption {
        type = types.attrsOf (types.submodule serviceModule);
        default = { };
        description = "Services run together in one environment container.";
      };
    };
  };

  config.assertions =
    map
      (name: {
        assertion = false;
        message = "biot environment variable name \"${name}\" must be a shell variable name";
      })
      invalidEnvironmentNames
    ++ map
      (name: {
        assertion = false;
        message = "biot environment variable \"${name}\" is reserved; use biot.packages for commands and the home mount for home data";
      })
      usedReservedEnvironmentNames
    ++ map
      (name: {
        assertion = false;
        message = "biot service name \"${name}\" may contain letters, numbers, periods, underscores, and hyphens";
      })
      invalidServiceNames
    ++ lib.optional (builtins.elem "biot-agent" serviceNames) {
      assertion = false;
      message = "biot service name \"biot-agent\" is reserved for the environment agent";
    }
    ++ map
      (name: {
        assertion = false;
        message = "biot file name \"${name}\" must be a relative path with no empty, \".\", or \"..\" segment";
      })
      invalidFileNames;
}
