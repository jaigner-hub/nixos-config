{
  description = "NixOS homelab — multi-machine flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, claude-code-nix }:
    let
      mkSystem = name: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit claude-code-nix; };
        modules = [
          ./machines/${name}/configuration.nix
        ];
      };
    in {
      nixosConfigurations = {
        nas = mkSystem "nas";
        dev = mkSystem "dev";
        fragrance-app = mkSystem "fragrance-app";
        gateway = mkSystem "gateway";
        monitor = mkSystem "monitor";
        nextcloud = mkSystem "nextcloud";
        vaultwarden = mkSystem "vaultwarden";
        adguard = mkSystem "adguard";
      };
    };
}
