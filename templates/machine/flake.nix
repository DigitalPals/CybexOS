{
  description = "Personal CybexOS machine; keep credentials outside this tree";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # The fresh installer replaces this with the authenticated exact release revision.
    cybexos.url = "github:DigitalPals/CybexOS/REPLACE_WITH_AUTHENTICATED_REVISION";
    cybexos.inputs.nixpkgs.follows = "nixpkgs";
    # Add personal inputs explicitly. cybex update never refreshes these implicitly.
  };
  outputs = { nixpkgs, cybexos, ... }: {
    nixosConfigurations.cybexos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ cybexos.nixosModules.default ./hardware-configuration.nix ./machine.nix ./settings.nix ./local ];
    };
  };
}
