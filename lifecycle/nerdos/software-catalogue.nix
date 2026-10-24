# Enumerate the machine's effective package set, including personal overlays.
# Nixpkgs deliberately contains throwing/unsupported attributes. Isolate each
# metadata evaluation rather than making a single bad package break discovery.
{ machine }:
let
  pkgs = (builtins.getFlake machine).nixosConfigurations.nerdos.pkgs;
  lib = pkgs.lib;
  visit = depth: prefix: value:
    let attempt = builtins.tryEval (builtins.deepSeq result result);
        result = if lib.isDerivation value then [{
          attribute = lib.concatStringsSep "." prefix;
          name = value.pname or (lib.getName value);
          version = value.version or "";
          description = value.meta.description or "";
        }] else if depth > 0 && builtins.isAttrs value && (value.recurseForDerivations or false)
          then walk (depth - 1) prefix value else [];
    in if attempt.success then attempt.value else [];
  walk = depth: prefix: set: lib.concatMap
    (name: visit depth (prefix ++ [ name ]) set.${name})
    (builtins.filter (name: builtins.match "[A-Za-z0-9_][A-Za-z0-9_+-]*" name != null)
      (builtins.attrNames set));
in walk 6 [] pkgs
