{ manifest, system }:

let
  manifestValue = builtins.fromJSON (builtins.readFile manifest);
  manifestFields = [ "base_nixpkgs" "digest" "layers" "project_snapshot" ];
  unexpectedFields = builtins.filter
    (name: !(builtins.elem name manifestFields))
    (builtins.attrNames manifestValue);
  missingFields = builtins.filter
    (name: !(builtins.elem name (builtins.attrNames manifestValue)))
    manifestFields;
  fieldErrors =
    (map (name: "manifest has unexpected field ${name}") unexpectedFields)
    ++ map (name: "manifest is missing field ${name}") missingFields;
  parsedManifest =
    if !builtins.isAttrs manifestValue then
      throw "manifest must be an attribute set"
    else if fieldErrors != [ ] then
      throw (builtins.concatStringsSep "\n" fieldErrors)
    else if !builtins.isString manifestValue.base_nixpkgs then
      throw "manifest field base_nixpkgs must be a string"
    else if !builtins.isList manifestValue.layers then
      throw "manifest field layers must be a list"
    else if !builtins.all builtins.isString manifestValue.layers then
      throw "manifest field layers must contain only strings"
    else
      manifestValue;

  sourceParts = source:
    let
      parts = builtins.filter builtins.isString (builtins.split "#" source);
    in
    if builtins.length parts == 3 then parts
    else throw "each pinned source must have the form <source>#<revision>#<NAR hash>";

  fetchPinnedSource = source:
    let
      parts = sourceParts source;
      sourceName = builtins.elemAt parts 0;
      rev = builtins.elemAt parts 1;
      narHash = builtins.elemAt parts 2;
      url = if sourceName == "nixpkgs" then "https://github.com/NixOS/nixpkgs" else sourceName;
    in
    builtins.fetchGit { inherit url rev narHash; shallow = true; };

  nixpkgsPath = fetchPinnedSource parsedManifest.base_nixpkgs;
  layerPaths = map fetchPinnedSource parsedManifest.layers;
  pkgs = import nixpkgsPath { inherit system; config = { }; overlays = [ ]; };
  inherit (pkgs) lib;

  mounts = {
    home = "/biot/home";
    serviceData = "/biot/service-data";
  };

  modulePath = path:
    let
      defaultModule = "${path}/default.nix";
    in
    if builtins.pathExists defaultModule then
      defaultModule
    else
      throw "layer source ${toString path} has no default.nix";

  evaluated = lib.evalModules {
    modules = [ ./module.nix ] ++ map modulePath layerPaths;
    specialArgs = { inherit pkgs; };
  };

  failedAssertions = builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions;
  config =
    if failedAssertions == [ ] then
      evaluated.config.biot
    else
      throw (lib.concatMapStringsSep "\n" (assertion: assertion.message) failedAssertions);

  shellEnvironment = environment:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList
        (name: value: "export ${name}=${lib.escapeShellArg value}")
        environment
    );

  environment = {
    HOME = mounts.home;
    PATH = lib.makeBinPath config.packages;
    BIOT_CONFIG_ROOT = toString configRoot;
  } // config.environment;

  environmentFile = pkgs.writeText "biot-environment" ''
    ${shellEnvironment environment}
  '';

  restartSettings = {
    always = ''
      autorestart=true
    '';
    on-failure = ''
      autorestart=unexpected
      exitcodes=0
    '';
    never = ''
      autorestart=false
    '';
  };

  serviceDirectory = service: "${mounts.serviceData}/${service.directory}";

  # A store path cannot contain "%", so the wrapper protects author values from supervisord interpolation.
  serviceScript = name: service:
    pkgs.writeShellApplication {
      name = "biot-service-${name}";
      text = ''
        ${shellEnvironment service.environment}
        cd ${lib.escapeShellArg (serviceDirectory service)}
        exec ${lib.escapeShellArgs service.command}
      '';
    };

  services = lib.mapAttrs
    (name: service: service // { script = serviceScript name service; })
    config.services;

  programConfig = name: service: ''
    [program:${name}]
    command=${service.script}/bin/biot-service-${name}
    # There is no startup phase, so the restart rule decides what happens after every exit.
    startsecs=0
    startretries=0
    stopasgroup=true
    killasgroup=true
    # Logs use the container streams, which require rotation to stay off.
    stdout_logfile=/dev/fd/1
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/fd/2
    stderr_logfile_maxbytes=0
    ${restartSettings.${service.restart}}
  '';

  supervisorConfig = pkgs.writeText "supervisord.conf" ''
    [supervisord]
    nodaemon=true
    logfile=/dev/null

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList programConfig services)}
  '';

  configRoot = pkgs.linkFarm "biot-config" (
    [
      {
        name = "supervisord.conf";
        path = supervisorConfig;
      }
    ]
    ++ lib.mapAttrsToList
      (path: file: {
        name = "files/${path}";
        path = pkgs.writeText "biot-file-${builtins.baseNameOf path}" file.text;
      })
      config.files
  );

  serviceDirectories = lib.concatStringsSep " " (
    lib.mapAttrsToList
      (_name: service: lib.escapeShellArg (serviceDirectory service))
      services
  );
  createServiceDirectories = lib.optionalString
    (serviceDirectories != "")
    "${pkgs.coreutils}/bin/mkdir -p ${serviceDirectories}";

  entrypoint = pkgs.writeShellApplication {
    name = "biot-entrypoint";
    # The generated environment file is a known store dependency, but shellcheck cannot open it here.
    excludeShellChecks = [ "SC1091" ];
    text = ''
      ${createServiceDirectories}
      . ${environmentFile}
      exec ${pkgs.python3Packages.supervisor}/bin/supervisord \
        --configuration ${configRoot}/supervisord.conf
    '';
  };

  entrypointPath = "${entrypoint}/bin/biot-entrypoint";
in
pkgs.runCommandLocal "biot-environment-bundle" {
  bundle = builtins.toJSON {
    format = 1;
    closure_root = builtins.placeholder "out";
    entrypoint = entrypointPath;
    environment_file = environmentFile;
    config_root = configRoot;
  };
} ''
  mkdir -p "$out"
  echo "$bundle" > "$out/bundle.json"
''
