# Oneshot service that gates downstream units on tailscale MagicDNS actually
# resolving the configured hostname. NFS mounts from nass race tailscaled at
# boot — `_netdev` only waits for *network*, and `Requires=tailscaled.service`
# only waits for the daemon to be active (DNS handshake completes later). This
# service polls `getent hosts <fqdn>` until it succeeds, so any unit ordered
# After= it knows MagicDNS works for real.
#
# Enable per-host with `homelab.waitForMagicDns.enable = true;`, then reference
# the service in fstab options on NFS mounts:
#
#   fileSystems."/mnt/foo" = {
#     device  = "nass.tail1ec6c3.ts.net:/mnt/storage/foo";
#     fsType  = "nfs4";
#     options = [
#       "nofail" "x-systemd.automount" "x-systemd.device-timeout=10" "_netdev"
#       "x-systemd.requires=wait-for-tailscale-magicdns.service"
#       "x-systemd.after=wait-for-tailscale-magicdns.service"
#     ];
#   };
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.waitForMagicDns;
in
{
  options.homelab.waitForMagicDns = {
    enable = lib.mkEnableOption "wait for tailscale MagicDNS at boot before NFS mounts";

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "nass.tail1ec6c3.ts.net";
      description = "MagicDNS hostname that must resolve before downstream units run.";
    };

    timeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 180;
      description = "Max seconds to wait. Service fails after this, blocking dependent mounts.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services."wait-for-tailscale-magicdns" = {
      description = "Wait for tailscale MagicDNS to resolve ${cfg.hostname}";
      wantedBy = [ "multi-user.target" ];
      after = [ "tailscaled.service" "network-online.target" ];
      wants = [ "tailscaled.service" "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "${toString cfg.timeoutSeconds}s";
        ExecStart = pkgs.writeShellScript "wait-magicdns" ''
          set -u
          attempts=$(( ${toString cfg.timeoutSeconds} / 2 ))
          for i in $(seq 1 "$attempts"); do
            if ${pkgs.getent}/bin/getent hosts ${cfg.hostname} >/dev/null 2>&1; then
              echo "MagicDNS resolved ${cfg.hostname} on attempt $i"
              exit 0
            fi
            sleep 2
          done
          echo "MagicDNS never resolved ${cfg.hostname} within ${toString cfg.timeoutSeconds}s" >&2
          exit 1
        '';
      };
    };
  };
}
