# Oneshot service that gates downstream units on the tailnet IPv4 address being
# ASSIGNED TO THE INTERFACE, not merely on tailscaled being active.
#
# `After=tailscaled.service` is not enough: the daemon reports active well before
# the kernel has the 100.x address on tailscale0. Any service that binds that
# address explicitly (rather than 0.0.0.0) therefore loses a race at boot and
# dies with `bind: cannot assign requested address`. Observed on monitor
# 2026-07-29 — BOTH keygrip witnesses (etcd-keygrip-app and
# stash-witness-keygrip) failed their first start that way and only came up on
# the systemd restart 5s later.
#
# Enable per-host, then order the binding units after it:
#
#   homelab.waitForTailnetIp = { enable = true; address = "100.109.229.12"; };
#
#   systemd.services.my-service = {
#     after = [ "wait-for-tailnet-ip.service" ];
#     wants = [ "wait-for-tailnet-ip.service" ];   # wants, NOT requires — see below
#   };
#
# Use `wants`, never `requires`: a `requires` on a oneshot that FAILS (address
# never arrives inside the timeout) would leave the downstream unit permanently
# down, which is strictly worse than the `Restart=on-failure` self-healing it
# has today. `wants` + `after` gives an ordered clean start in the normal case
# and keeps the restart loop as the backstop in the pathological one.
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.waitForTailnetIp;
in
{
  options.homelab.waitForTailnetIp = {
    enable = lib.mkEnableOption "wait for the tailnet IP to be assigned before address-binding units start";

    address = lib.mkOption {
      type = lib.types.str;
      description = "Tailnet IPv4 that must be present on the interface before downstream units run.";
      example = "100.109.229.12";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "tailscale0";
      description = "Interface the address is expected on.";
    };

    timeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "Max seconds to wait. The service fails after this; dependents still start (wants, not requires).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services."wait-for-tailnet-ip" = {
      description = "Wait for tailnet address ${cfg.address} on ${cfg.interface}";
      wantedBy = [ "multi-user.target" ];
      after = [ "tailscaled.service" "network-online.target" ];
      wants = [ "tailscaled.service" "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "${toString cfg.timeoutSeconds}s";
        ExecStart = pkgs.writeShellScript "wait-tailnet-ip" ''
          set -u
          attempts=$(( ${toString cfg.timeoutSeconds} / 2 ))
          for i in $(seq 1 "$attempts"); do
            if ${pkgs.iproute2}/bin/ip -4 -o addr show dev ${cfg.interface} 2>/dev/null \
                 | grep -qwF ${cfg.address}; then
              echo "tailnet address ${cfg.address} is up on ${cfg.interface} (attempt $i)"
              exit 0
            fi
            sleep 2
          done
          echo "tailnet address ${cfg.address} never appeared on ${cfg.interface} within ${toString cfg.timeoutSeconds}s" >&2
          exit 1
        '';
      };
    };
  };
}
