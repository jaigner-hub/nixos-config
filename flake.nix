{
  description = "NAS server config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = {
    nixosConfigurations = {
      nas = nixpkgs.lib.nixosSystem {
        system = "x85_64-linux";
        modules = [
          ./hardware-configuration.nix
          ./configuration.nix
        ];
      };
    };
  };
}
