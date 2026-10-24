{ ... }:
let choices = builtins.fromJSON (builtins.readFile ./software.json);
in {
  assertions = [{ assertion = choices.schema == 1; message = "Unsupported personal software declaration"; }];
  nerdos.software.packages = choices.packages;
}
