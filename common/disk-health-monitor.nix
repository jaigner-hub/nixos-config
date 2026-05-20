# Per-drive health monitor with ntfy alerts. Catches the failure modes that
# bit nass on 2026-05-18 (drive disappeared from SCSI bus, mount went to
# read-only) faster than the next nightly backup or end-user 502.
#
# Checks per drive every `interval`:
#   1. mountpoint is mounted
#   2. mountpoint is writable (filesystem hasn't been remounted read-only
#      after a journal abort)
#   3. SMART overall-health says PASSED
#
# A non-zero exit triggers the ntfy-failed-disk-health-check unit which
# publishes to the homelab-critical topic.
#
# Enable per-host:
#   homelab.diskHealthMonitor = {
#     enable = true;
#     drives = [
#       { label = "hdd1"; mountpoint = "/mnt/hdd1";
#         device = "/dev/disk/by-id/ata-ST24000DM001-3Y7103_ZXA0MYAH"; }
#     ];
#   };
#
# Prefer /dev/disk/by-id/ over /dev/sdX — after a SCSI rescan the kernel
# may re-enumerate the drive (sdb → sdd), but the by-id symlink follows
# the hardware.
{ config, lib, pkgs, mkNtfyOnFailure, ... }:

let
  cfg = config.homelab.diskHealthMonitor;

  checkScript = pkgs.writeShellScript "disk-health-check" ''
    set -u
    failures=()

    check_drive() {
      local label="$1" mountpoint="$2" device="$3"

      if ! ${pkgs.util-linux}/bin/mountpoint -q "$mountpoint"; then
        failures+=("$label: $mountpoint is not mounted")
        return
      fi

      local sentinel="$mountpoint/.disk-health-check"
      if ! touch "$sentinel" 2>/dev/null; then
        failures+=("$label: $mountpoint not writable (filesystem may be remounted read-only after I/O error)")
        return
      fi
      rm -f "$sentinel"

      if [ ! -e "$device" ]; then
        failures+=("$label: SMART device $device not present (drive may be disconnected)")
        return
      fi
      local smart_out smart_status
      smart_out=$(${pkgs.smartmontools}/bin/smartctl -H "$device" 2>&1 || true)
      smart_status=$(echo "$smart_out" | grep -E "(overall-health|SMART Health Status)" || true)
      if ! echo "$smart_status" | grep -qE "(PASSED|OK)"; then
        failures+=("$label: SMART check on $device did not report PASSED — $smart_status")
      fi
    }

    ${lib.concatMapStringsSep "\n" (d:
      "check_drive ${lib.escapeShellArg d.label} ${lib.escapeShellArg d.mountpoint} ${lib.escapeShellArg d.device}"
    ) cfg.drives}

    if [ ''${#failures[@]} -gt 0 ]; then
      echo "Disk health check FAILED (${toString (lib.length cfg.drives)} drives monitored):"
      for f in "''${failures[@]}"; do
        echo "  - $f"
      done
      exit 1
    fi
    echo "All ${toString (lib.length cfg.drives)} drives healthy"
  '';
in
{
  options.homelab.diskHealthMonitor = {
    enable = lib.mkEnableOption "per-drive mount/writable/SMART monitoring with ntfy alerts";

    drives = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          label = lib.mkOption {
            type = lib.types.str;
            description = "Human-readable name used in ntfy alert text (e.g. \"hdd1\").";
          };
          mountpoint = lib.mkOption {
            type = lib.types.str;
            description = "Where the drive is mounted (e.g. /mnt/hdd1).";
          };
          device = lib.mkOption {
            type = lib.types.str;
            description = "Stable device path for SMART — prefer /dev/disk/by-id/ over /dev/sdX (survives SCSI re-enumeration).";
          };
        };
      });
      default = [ ];
      description = "Drives to monitor.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = "systemd OnUnitActiveSec value — how often to re-check.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.smartmontools ];

    systemd.services.disk-health-check = {
      description = "Verify monitored drives are mounted, writable, and SMART-healthy";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${checkScript}";
      };
    };

    systemd.timers.disk-health-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.interval;
        Unit = "disk-health-check.service";
      };
    };

    systemd.services."ntfy-failed-disk-health-check" =
      mkNtfyOnFailure {
        topic = "homelab-critical";
        title = "${config.networking.hostName}: disk health check FAILED";
      } "disk-health-check.service";
    systemd.services.disk-health-check.onFailure = [ "ntfy-failed-disk-health-check.service" ];
  };
}
