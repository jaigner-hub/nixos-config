{ config, pkgs, claude-code-nix, ... }:

{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "gateway";
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "jeff.aigner@gmail.com";
  };

  services.caddy = {
    enable = true;

    # Reverse-proxy public hostnames to backend services reachable over Tailscale.
    # Caddy auto-provisions Let's Encrypt certs for each virtualHosts entry, so
    # the hostname must resolve publicly to this gateway over 80/443.
    virtualHosts = {
      # "jellyfin.example.com".extraConfig = ''
      #   reverse_proxy http://nas:8096
      # '';
      # "fragrance.example.com".extraConfig = ''
      #   reverse_proxy http://fragrance-app:80
      # '';
      # "git.example.com".extraConfig = ''
      #   reverse_proxy http://git:3000
      # '';
    };
  };

  system.stateVersion = "25.11";
}
