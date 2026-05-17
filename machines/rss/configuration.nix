{ config, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:

{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "rss";

  # Miniflux: single-binary Go RSS reader, Postgres backend (auto-provisioned
  # by the module). Bound to loopback; nginx terminates TLS and proxies in.
  # Admin user seeded from the creds file on first start; provision before
  # first activation or the unit will fail with a missing EnvironmentFile.
  #   printf 'ADMIN_USERNAME=admin\nADMIN_PASSWORD=<pw>\n' \
  #     | sudo install -m 600 -o root -g root /dev/stdin /etc/miniflux-admin-creds
  services.miniflux = {
    enable = true;
    adminCredentialsFile = "/etc/miniflux-admin-creds";
    config = {
      LISTEN_ADDR = "127.0.0.1:8080";
      BASE_URL = "https://rss.tail1ec6c3.ts.net";
      LOG_FORMAT = "json";
    };
  };

  system.stateVersion = "25.11";
}
