{ ... }:
let choices = builtins.fromJSON (builtins.readFile ./maintenance.json);
in {
  assertions = [{ assertion = choices.schema == 1; message = "Unsupported personal cleanup declaration"; }];
  cybexos.maintenance = choices.policy;
}
