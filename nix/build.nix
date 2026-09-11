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
  layerModules = map modulePath layerPaths;
  pkgs = import nixpkgsPath { inherit system; config = { }; overlays = [ ]; };
  inherit (pkgs) lib;
  agent = import ./agent.nix { inherit pkgs; };

  mounts = {
    checkout = "/biot/checkout";
    home = "/biot/home";
    service_data = "/biot/service-data";
    run = "/biot/run";
    secrets = "/biot/secrets";
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
    modules = [ ./module.nix ] ++ layerModules;
    specialArgs = { inherit pkgs; };
  };

  failedAssertions = builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions;
  config =
    if failedAssertions == [ ] then
      evaluated.config.biot
    else
      throw ''
        ${lib.concatMapStringsSep "\n" (assertion: assertion.message) failedAssertions}
        sources:
        ${lib.concatMapStringsSep "\n" (source: "- ${source}") layerModules}
      '';

  configRoot = pkgs.linkFarm "biot-config" (
    lib.mapAttrsToList
      (path: file: {
        name = "files/${path}";
        path = pkgs.writeText "biot-file-${builtins.baseNameOf path}" file.text;
      })
      config.files
  );

  shellEnvironment = environment:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList
        (name: value: "export ${name}=${lib.escapeShellArg value}")
        environment
    );

  environment = {
    HOME = mounts.home;
    PATH = lib.makeBinPath ([ pkgs.bash pkgs.coreutils config.shell ] ++ config.packages);
    BIOT_CONFIG_ROOT = toString configRoot;
  } // config.environment;

  environmentFile = pkgs.writeText "biot-environment" ''
    ${shellEnvironment environment}
  '';

  loadEnvironment = serviceEnvironment: ''
    . ${environmentFile}
    ${shellEnvironment serviceEnvironment}
    for secret_path in ${mounts.secrets}/*; do
      [ -f "$secret_path" ] || continue
      secret_name="''${secret_path##*/}"
      export "$secret_name=$(${pkgs.coreutils}/bin/cat -- "$secret_path")"
    done
  '';

  serviceDirectory = service:
    "${mounts.${service.directory.root}}/${service.directory.path}";

  # Every entry starts from a clean environment, and this is the one definition of that rule.
  # Each `keep` entry is a shell-quoted NAME=value assignment that survives the clearing.
  cleanEnvironment = keep: command:
    lib.concatStringsSep " " ([ "${pkgs.coreutils}/bin/env" "-i" ] ++ keep ++ [ command ]);

  serviceCommand = name: service:
    pkgs.writeShellApplication {
      name = "biot-service-${name}";
      excludeShellChecks = [ "SC1091" ];
      text = ''
        ${loadEnvironment service.environment}
        cd ${lib.escapeShellArg (serviceDirectory service)}
        exec ${lib.escapeShellArgs service.command}
      '';
    };

  shellCommand = pkgs.writeShellApplication {
    name = "biot-shell-command";
    excludeShellChecks = [ "SC1091" ];
    text = ''
      ${loadEnvironment { }}
      cd ${mounts.checkout}
      if [ "$#" -gt 0 ]; then
        exec "$@"
      fi
      exec ${lib.getExe config.shell}
    '';
  };

  shellEntrypoint = pkgs.writeShellApplication {
    name = "biot-shell-entrypoint";
    text = ''
      term="''${TERM-}"
      exec ${cleanEnvironment [ ''TERM="$term"'' ] "${shellCommand}/bin/biot-shell-command"} "$@"
    '';
  };

  restartAttemptLimit = 5;
  restartBackoffInitialSeconds = 1;
  restartBackoffMaximumSeconds = 4;
  # A run this long ended for its own reason rather than in a restart loop, so the attempts start
  # counting again.
  restartHealthyRunSeconds = 60;
  # Exhaustion is the runner's failure, not the program's, so it reports one status of its own.
  # The program's last status goes in the diagnostic, where a reader can tell the two apart.
  restartExhaustedStatus = 70;

  restartCondition = {
    always = "true";
    on-failure = ''[ "$status" -ne 0 ]'';
    never = "false";
  };

  # Supervisord limits only startup failures, so this loop owns runtime restart limits and backoff.
  restartCommand = name: launch: restart:
    pkgs.writeShellApplication {
      name = "biot-run-${name}";
      text = ''
        attempt=1
        while true; do
          started=$SECONDS
          set +e
          ${launch}
          status=$?
          set -e

          if ! ${restartCondition.${restart}}; then
            exit "$status"
          fi
          if [ $(( SECONDS - started )) -ge ${toString restartHealthyRunSeconds} ]; then
            attempt=1
          fi
          if [ "$attempt" -ge ${toString restartAttemptLimit} ]; then
            printf 'biot service %s exhausted restart attempts after %s starts since the last healthy run; last exit status %s\n' \
              ${lib.escapeShellArg name} "$attempt" "$status" >&2
            exit ${toString restartExhaustedStatus}
          fi

          delay=$(( ${toString restartBackoffInitialSeconds} << (attempt - 1) ))
          if [ "$delay" -gt ${toString restartBackoffMaximumSeconds} ]; then
            delay=${toString restartBackoffMaximumSeconds}
          fi
          ${pkgs.coreutils}/bin/sleep "$delay"
          attempt=$((attempt + 1))
        done
      '';
    };

  services = lib.mapAttrs
    (name: service:
      service // {
        launch = cleanEnvironment [ ] "${serviceCommand name service}/bin/biot-service-${name}";
      })
    config.services;

  programs = services // {
    "biot-agent" = {
      launch = cleanEnvironment [ ] (lib.concatStringsSep " " [
        "${agent}/bin/biot-agent"
        "--socket ${mounts.run}/agent.sock"
        "--shell-entrypoint ${shellEntrypoint}/bin/biot-shell-entrypoint"
      ]);
      restart = "always";
    };
  };

  programConfig = name: program:
    let
      runner = restartCommand name program.launch program.restart;
    in
    ''
      [program:${name}]
      command=${runner}/bin/biot-run-${name}
      startsecs=0
      startretries=0
      autorestart=false
      stopasgroup=true
      killasgroup=true
      stdout_logfile=/dev/fd/1
      stdout_logfile_maxbytes=0
      stderr_logfile=/dev/fd/2
      stderr_logfile_maxbytes=0
    '';

  supervisorConfig = pkgs.writeText "supervisord.conf" ''
    [supervisord]
    nodaemon=true
    logfile=/dev/null
    pidfile=/run/supervisord.pid
    childlogdir=/run
    user=root

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList programConfig programs)}
  '';

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
    text = ''
      ${createServiceDirectories}
      exec ${cleanEnvironment [ ] "${pkgs.python3Packages.supervisor}/bin/supervisord --configuration ${supervisorConfig}"}
    '';
  };

  rootfs = pkgs.runCommandLocal "biot-rootfs" { } ''
    mkdir -p \
      "$out/bin" \
      "$out/usr/bin" \
      "$out/etc" \
      "$out/biot/checkout" \
      "$out/biot/home" \
      "$out/biot/service-data" \
      "$out/biot/run" \
      "$out/biot/secrets" \
      "$out/nix/store" \
      "$out/dev" \
      "$out/proc" \
      "$out/sys" \
      "$out/tmp" \
      "$out/run"
    ln -s ${pkgs.bash}/bin/bash "$out/bin/sh"
    ln -s ${pkgs.coreutils}/bin/env "$out/usr/bin/env"
    printf 'root:x:0:0:root:/biot/home:/bin/sh\n' >"$out/etc/passwd"
    printf 'root:x:0:\n' >"$out/etc/group"
    printf 'passwd: files\ngroup: files\nhosts: files dns\n' >"$out/etc/nsswitch.conf"
    touch "$out/etc/hosts" "$out/etc/hostname" "$out/etc/resolv.conf"
  '';
in
pkgs.runCommandLocal "biot-environment-bundle" {
  bundle = builtins.toJSON {
    format = 1;
    closure_root = builtins.placeholder "out";
    inherit rootfs;
    entrypoint = "${entrypoint}/bin/biot-entrypoint";
    shell_entrypoint = "${shellEntrypoint}/bin/biot-shell-entrypoint";
    environment_file = environmentFile;
    config_root = configRoot;
  };
} ''
  mkdir -p "$out"
  echo "$bundle" >"$out/bundle.json"
''
