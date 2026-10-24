{ config, options, lib, pkgs, ... }:
let
  cfg = config.cybexos;
  selected = map (name: {
    attribute = name;
    package = lib.attrByPath (lib.splitString "." name)
      (throw "Software package ${name} is unavailable in the machine's locked Nixpkgs") pkgs;
  }) cfg.software.packages;
  elsewhere = lib.concatMap (definition: map toString definition.value)
    (builtins.filter (definition: definition.file != toString ./software.nix)
      options.environment.systemPackages.definitionsWithLocations);
in {
  options.cybexos.software.packages = lib.mkOption {
    type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9_][A-Za-z0-9_+.-]*");
    default = [];
    description = "Native package attributes selected through the staged Software interface.";
  };
  config = lib.mkIf cfg.enable {
    assertions = map (entry: {
      assertion = builtins.elem (toString entry.package) (map toString config.environment.systemPackages);
      message = "Software selection ${entry.attribute} is excluded by another systemPackages definition. Preserve that declaration and resolve the conflict explicitly.";
    }) selected;
    environment.systemPackages = map (entry: entry.package) selected;
    environment.etc."cybexos/software.json".text = builtins.toJSON {
      schema = 1;
      selected = cfg.software.packages;
      packages = lib.unique (map (package: {
        path = toString package;
        name = package.pname or (lib.getName package);
        version = package.version or "";
        description = package.meta.description or "";
        attributes = map (entry: entry.attribute)
          (builtins.filter (entry: toString entry.package == toString package) selected);
        managedElsewhere = builtins.elem (toString package) elsewhere;
      }) config.environment.systemPackages);
    };
  };
}
