{
  description = "NixOS homelab — multi-machine flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, claude-code-nix }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      hostNames = [
        "nas"
        "dev"
        "monitor"
        "nextcloud"
        "vaultwarden"
        "adguard"
      ];

      # Directory name == tailscale MagicDNS name, except `nas` uses hostname `nass`.
      targetHostFor = name: if name == "nas" then "nass" else name;

      mkSystem = name: lib.nixosSystem {
        inherit system;
        specialArgs = { inherit claude-code-nix; };
        modules = [ ./machines/${name}/configuration.nix ];
      };

      mkColmenaNode = name: { ... }: {
        deployment = {
          targetHost = targetHostFor name;
          targetUser = "jeff";
        };
        imports = [ ./machines/${name}/configuration.nix ];
      };
    in {
      nixosConfigurations = lib.genAttrs hostNames mkSystem;

      colmena = {
        meta = {
          nixpkgs = import nixpkgs { inherit system; };
          specialArgs = { inherit claude-code-nix; };
        };
      } // lib.genAttrs hostNames mkColmenaNode;
    };
}
