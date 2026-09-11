# The trusted fetch phase. It runs in a build worker with network access and no user code, and it
# is the only place Biot resolves a moving ref or reaches a repository.
#
# Output contract, read by the node:
#
#   <out>/pins.json      a real file: { build_support, base_nixpkgs, layers }, each entry naming
#                        the store path that holds it and the NAR hash that names those bytes, and
#                        each source also naming the revision it was pinned to
#   <out>/nixpkgs        a symlink to the fetched base package set
#   <out>/layer-<n>      a symlink to each fetched layer, in selection order
#   <out>/build-support  a symlink to the release build support this resolution was staged with
#
# The symlinks exist for retention: they make the whole set part of this derivation's closure, so
# the one out-link the node keeps is the one garbage collection root every staged input needs. The
# node reads `pins.json` and mounts the store paths it names into the build worker, which is the
# only way that worker gets a source. Nothing fetches anything after this phase.
#
# Entry order follows the selection, and the selection is what says which entry is the base
# package set, so no entry has to name itself.
{ selection, buildSupport, system }:

let
  parsed = builtins.fromJSON selection;

  # A ref that is already a commit is a pin, not a branch to resolve, and Git only looks a branch
  # name up under `refs/`.
  isRevision = ref: builtins.match "[0-9a-f]{40}" ref != null;

  fetchSource = entry:
    if isRevision entry.ref then
      builtins.fetchGit { inherit (entry) url; rev = entry.ref; shallow = true; }
    else
      builtins.fetchGit { inherit (entry) url ref; shallow = true; };

  pin = source: {
    store_path = toString source;
    revision = source.rev;
    nar_hash = source.narHash;
  };

  nixpkgsSource = fetchSource parsed.base_nixpkgs;
  layerSources = map fetchSource parsed.layers;

  # `fetchTree` is the one way a pure evaluation can name this tree later, and it is the only way
  # to learn the hash that names it.
  buildSupportTree = builtins.fetchTree { type = "path"; path = buildSupport; };

  pins = {
    build_support = {
      store_path = toString buildSupportTree;
      nar_hash = buildSupportTree.narHash;
    };
    base_nixpkgs = pin nixpkgsSource;
    layers = map pin layerSources;
  };

  pkgs = import nixpkgsSource { inherit system; config = { }; overlays = [ ]; };

  pinsFile = pkgs.writeText "biot-pins.json" (builtins.toJSON pins);

  layerLinks = pkgs.lib.concatImapStringsSep "\n"
    (index: source: "ln -s ${source} \"$out/layer-${toString (index - 1)}\"")
    layerSources;
in
pkgs.runCommandLocal "biot-staged-inputs" { } ''
  mkdir -p "$out"
  cp ${pinsFile} "$out/pins.json"
  ln -s ${nixpkgsSource} "$out/nixpkgs"
  ln -s ${buildSupportTree} "$out/build-support"
  ${layerLinks}
''
