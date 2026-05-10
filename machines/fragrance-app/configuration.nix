{ config, pkgs, claude-code-nix, ... }:

let
  appUser = "fragrance-app";
  appHome = "/srv/fragrance-app";
  appVenv = "${appHome}/venv";
  appSocket = "/run/fragrance-app/gunicorn.sock";
  dbName = "fragrance_app";
in
{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "fragrance-app";
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  environment.systemPackages = with pkgs; [
    python3
    python3Packages.pip
    python3Packages.virtualenv

    mariadb.client

    gcc
    gnumake
    pkg-config
    libmysqlclient
    libffi
    openssl
    zlib
  ];

  users.groups.${appUser} = { };
  users.users.${appUser} = {
    isSystemUser = true;
    group = appUser;
    home = appHome;
    createHome = true;
    shell = pkgs.bashInteractive;
  };

  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    ensureDatabases = [ dbName ];
    ensureUsers = [
      {
        name = appUser;
        ensurePermissions = {
          "${dbName}.*" = "ALL PRIVILEGES";
        };
      }
    ];
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    virtualHosts."_" = {
      default = true;
      locations."/" = {
        proxyPass = "http://unix:${appSocket}";
      };
      locations."/static/" = {
        alias = "${appHome}/static/";
      };
      locations."/media/" = {
        alias = "${appHome}/media/";
      };
    };
  };

  systemd.services.fragrance-app = {
    description = "Fragrance Lab Django app (gunicorn)";
    after = [ "network.target" "mysql.service" ];
    wants = [ "mysql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "notify";
      User = appUser;
      Group = appUser;
      WorkingDirectory = appHome;
      RuntimeDirectory = "fragrance-app";
      RuntimeDirectoryMode = "0750";
      EnvironmentFile = "/etc/fragrance-app.env";
      ExecStart = "${appVenv}/bin/gunicorn --bind unix:${appSocket} --workers 3 fragrance_app.wsgi:application";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  users.users.nginx.extraGroups = [ appUser ];

  system.stateVersion = "25.11";
}
