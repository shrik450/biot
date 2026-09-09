{ url, ref }:

let
  source = builtins.fetchGit {
    inherit url ref;
    shallow = true;
  };
in
{
  revision = source.rev;
  nar_hash = source.narHash;
}
