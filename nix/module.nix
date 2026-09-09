{ config, lib, ... }:

let
  inherit (lib) mkOption types;

  validEnvironmentName = name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null;
  validServiceName = name: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name != null;
  validRelativePath = path:
    path != ""
    && !(lib.hasPrefix "/" path)
    && builtins.all (part: part != "" && part != "." && part != "..") (lib.splitString "/" path);
  relativePath = types.addCheck types.str validRelativePath // {
    name = "relativePath";
    description = "relative path with no empty, \".\", or \"..\" segment";
  };

  fileModule = {
    options.text = mkOption {
      type = types.str;
      description = "The complete contents of the immutable file.";
    };
  };

  serviceModule = { name, ... }: {
    options = {
      command = mkOption {
        type = types.nonEmptyListOf types.str;
        description = "The executable and arguments for the service.";
      };

      directory = mkOption {
        type = relativePath;
        default = name;
        description = "The directory below the service data mount where the service runs.";
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
  reservedEnvironmentNames = [ "BIOT_CONFIG_ROOT" "HOME" "PATH" ];
  invalidEnvironmentNames = builtins.filter
    (name: !validEnvironmentName name)
    (environmentNames ++ serviceEnvironmentNames);
  invalidReservedEnvironmentNames = builtins.filter
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
        description = "Packages placed on PATH for every service.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Environment variables shared by every service.";
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
      invalidReservedEnvironmentNames
    ++ map
      (name: {
        assertion = false;
        message = "biot service name \"${name}\" may contain letters, numbers, periods, underscores, and hyphens";
      })
      invalidServiceNames
    ++ map
      (name: {
        assertion = false;
        message = "biot file name \"${name}\" must be a relative path with no empty, \".\", or \"..\" segment";
      })
      invalidFileNames;
}
