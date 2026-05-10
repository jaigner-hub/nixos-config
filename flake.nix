{
  description = "NAS server config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
  };

  outputs = {self, nixpkgs, claude-code-nix}: {
    nixosConfigurations = {
      nas = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit claude-code-nix; }; 
        modules = [
          ./hardware-configuration.nix
          ./configuration.nix
        ];
      };
    };
  };
}
