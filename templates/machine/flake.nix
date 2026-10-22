{
  description = "Personal NerdOS machine; keep credentials outside this tree";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # The fresh installer replaces this with the authenticated exact release revision.
    nerdos.url = "github:DigitalPals/NerdOS/REPLACE_WITH_AUTHENTICATED_REVISION";
    nerdos.inputs.nixpkgs.follows = "nixpkgs";
    # Add personal inputs explicitly. nerd update never refreshes these implicitly.
  };
  outputs = { nixpkgs, nerdos, ... }: {
    nixosConfigurations.nerdos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ nerdos.nixosModules.default ./hardware-configuration.nix ./machine.nix ./settings.nix ./local ];
    };
  };
}
