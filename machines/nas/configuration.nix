{ config, lib, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:

let
  pythonWithPackages = pkgs.python3.withPackages (ps: with ps; [
    requests
  ]);
  syncScript = pkgs.writeScriptBin "putio-sync" (builtins.readFile ../../scripts/putio-sync.py);
  sleepTimerPlugin = import ./jellyfin-sleep-timer.nix { inherit pkgs; };
  # Jellyfin's plugin loader expects a 4-component version in the directory
  # name (Plugin.Version.ToString() = "1.1.0.0", not "1.1.0").
  sleepTimerPluginDir = "/var/lib/jellyfin/plugins/SleepTimer_${sleepTimerPlugin.version}.0";
  b2Bucket = "Backup-jaigner-homelab";
  b2Endpoint = "s3.us-east-005.backblazeb2.com";
  publicFqdn = "files.youtalklikeafag.com";
  tunnelId = "2b4f31f7-96a2-4df5-9544-a8b57f21a380";
in
{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nass";

  environment.systemPackages = with pkgs; [
    iotop
    jellyfin
    samba
    mergerfs
    pythonWithPackages
    gcc
    gnumake
    gdb
    unixtools.netstat
    ffmpeg-full
    smartmontools
    hdparm
    parted
    ncdu
    p7zip
  ];

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  # SleepTimer plugin: drop the prebuilt DLL into Jellyfin's plugins dir
  # via tmpfiles, and restart Jellyfin whenever the derivation hash changes
  # so version bumps activate without a manual restart.
  systemd.services.jellyfin.restartTriggers = [ sleepTimerPlugin ];

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "nass";
      };
      media = {
        path = "/mnt/storage";
        browseable = "yes";
        "read only" = "no";
      };
    };
  };

  users.groups.nextcloud = {
    gid = 5000;
  };
  users.users.nextcloud = {
    isSystemUser = true;
    group = "nextcloud";
    uid = 5000;
    description = "Nextcloud data owner (NFS UID/GID parity)";
  };

  users.groups.immich = {
    gid = 5001;
  };
  users.users.immich = {
    isSystemUser = true;
    group = "immich";
    uid = 5001;
    description = "Immich data owner (NFS UID/GID parity)";
  };

  # `fsid=` is required because /mnt/storage is mergerfs (FUSE), which
  # doesn't expose a stable device ID for the kernel NFS server to use
  # when generating filehandles. Numbers are arbitrary but must be unique
  # and stable across reboots — never reuse a number for a different path.
  services.nfs.server = {
    enable = true;
    exports = ''
      /mnt/storage/nextcloud 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash,fsid=1)
      /mnt/storage/immich    100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash,fsid=2)
    '';
  };

  services.nfs.settings = {
    nfsd.vers3 = false;
    nfsd.vers4 = true;
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 2049 ];

  # Physical disks passed through from the Proxmox host as raw SCSI.
  # Union-mounted at /mnt/storage via mergerfs so the 21.8 TB and 4.5 TB
  # drives appear as one ~26 TB filesystem — the asymmetric sizes are
  # why mergerfs over plain LVM/btrfs-raid: no per-disk size matching
  # required, and a single disk loss only loses that disk's data.
  # `nofail` keeps the host bootable if a drive disappears.
  fileSystems."/mnt/hdd1" = {
    device = "/dev/disk/by-uuid/ca1567d9-3634-4e46-acd9-545d7525371b";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=10" ];
  };

  fileSystems."/mnt/hdd2" = {
    device = "/dev/disk/by-uuid/f15c866f-d200-4b12-866f-bd36c79c626b";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=10" ];
  };

  fileSystems."/mnt/storage" = {
    device = "/mnt/hdd1:/mnt/hdd2";
    fsType = "fuse.mergerfs";
    options = [ "nofail" "x-systemd.device-timeout=10" ];
  };

  systemd.tmpfiles.rules = [
    # jellyfin owns the root so putio-sync (running as jellyfin) can create
    # top-level media folders like Movies/, TV Shows/, etc. Mode 0755 keeps
    # the directory world-listable so filebrowser/nfs clients can traverse
    # it, but only jellyfin can create new entries at the root.
    "d /mnt/storage 0755 jellyfin jellyfin -"
    "d /mnt/storage/nextcloud 0700 nextcloud nextcloud -"
    "d /mnt/storage/immich 0700 immich immich -"
    # Writable drop-zone for filebrowser. /mnt/storage itself is owned by
    # jellyfin, so filebrowser can list it but not create files there —
    # this gives it one subdirectory it owns for share-link use.
    "d /mnt/storage/shared 0755 filebrowser filebrowser -"
    # SleepTimer plugin install. `L+` overwrites any prior symlink so
    # version bumps land cleanly on rebuild. Only the DLL is symlinked
    # from /nix/store; meta.json is written by Jellyfin at runtime and
    # stays in /var/lib (mutable).
    "d ${sleepTimerPluginDir} 0700 jellyfin jellyfin -"
    "L+ ${sleepTimerPluginDir}/Jellyfin.Plugin.SleepTimer.dll - - - - ${sleepTimerPlugin}/lib/Jellyfin.Plugin.SleepTimer.dll"
  ];

  systemd.services.putio-sync = {
    description = "put.io sync";
    serviceConfig = {
      ExecStart = "${pythonWithPackages}/bin/python3 ${syncScript}/bin/putio-sync";
      Type = "oneshot";
      EnvironmentFile = "/etc/putio-sync.env";
      # The script shells out via `sudo -u jellyfin ...`. On NixOS, the
      # setuid sudo wrapper lives at /run/wrappers/bin/sudo; without it on
      # PATH, subprocess.run(["sudo", ...]) fails with FileNotFoundError.
      # sudo's default secure_path (set by the nixpkgs module) handles
      # finding cat/tee/mkdir/curl/find once sudo itself starts.
      Environment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin";
    };
  };

  systemd.timers.putio-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
    };
  };

  # Filebrowser: lightweight web UI for browsing /mnt/storage and
  # generating share links for external recipients. Listens on
  # loopback only; cloudflared (added below) handles public ingress.
  services.filebrowser = {
    enable = true;
    settings = {
      address = "127.0.0.1";
      port = 8334;
      root = "/mnt/storage";
    };
  };

  # The upstream filebrowser module emits a tmpfiles rule that chmods
  # settings.root to filebrowser:filebrowser 0700. For us that root is
  # /mnt/storage, which Samba/Jellyfin/NFS/restic all read — locking
  # it to one user would break every other service on this host.
  # Override the single offending rule (the existing 0755 root:root
  # tmpfiles rule already declared above stays in effect).
  systemd.tmpfiles.settings.filebrowser."/mnt/storage" = lib.mkForce {};

  # Seed/refresh the filebrowser admin user from /etc/filebrowser-password
  # on every start. First boot: `config init` creates the empty BoltDB,
  # then `users add` creates jeff (the update branch fails silently
  # because no user exists yet). Subsequent boots: `users update`
  # succeeds and re-syncs the password from the file, so rotating means
  # edit the file and `systemctl restart filebrowser`.
  #
  # `users add` is split from setting --scope because filebrowser 2.63
  # has a long-running bug where passing `--scope` on the add path
  # fails with `failed to create user home dir: [<scope>]: mkdir
  # <scope>: file does not exist` even when the directory already
  # exists and is accessible (filebrowser/filebrowser#3346). Workaround
  # is `users add` with no scope, then `users update --scope` to set
  # it. Idempotent: the update branch covers all subsequent boots.
  #
  # The `+` prefix runs this as root (needed to read the 0600 password
  # file). All filebrowser CLI calls then drop to the filebrowser user
  # via runuser so the BoltDB ends up correctly owned for the main
  # service process (which also runs as the filebrowser user).
  systemd.services.filebrowser.serviceConfig.ExecStartPre = let
    fb = "${config.services.filebrowser.package}/bin/filebrowser";
    db = config.services.filebrowser.settings.database;
    fbUser = config.services.filebrowser.user;
    runuser = "${pkgs.util-linux}/bin/runuser";
    seed = pkgs.writeShellScript "filebrowser-seed-admin" ''
      set -euo pipefail
      pw=$(cat /etc/filebrowser-password)
      if [ ! -f ${db} ]; then
        ${runuser} -u ${fbUser} -- ${fb} -d ${db} config init
      fi
      # Scope is relative to settings.root (/mnt/storage), so "/" gives
      # jeff the entire configured root. Setting scope to /mnt/storage
      # would have filebrowser look under /mnt/storage/mnt/storage.
      if ! ${runuser} -u ${fbUser} -- ${fb} -d ${db} users update jeff --password "$pw" --scope / 2>/dev/null; then
        ${runuser} -u ${fbUser} -- ${fb} -d ${db} users add jeff "$pw" --perm.admin
        ${runuser} -u ${fbUser} -- ${fb} -d ${db} users update jeff --scope /
      fi
    '';
  in [ "+${seed}" ];

  # Public access via Cloudflare Tunnel. The outbound cloudflared
  # daemon holds a connection to Cloudflare's edge and forwards requests
  # to filebrowser on loopback; TLS terminates at the edge. LAN access
  # via Samba on this host stays direct and is unaffected.
  #
  # Credentials provisioned out-of-band at /etc/cloudflared/<uuid>.json
  # (root:root 0600). The nixpkgs module uses DynamicUser + LoadCredential,
  # so systemd reads the file as root before privilege drop. After the
  # first deploy: `sudo mkdir -p /etc/cloudflared && sudo install -m 600
  # -o root -g root <src> /etc/cloudflared/${tunnelId}.json` then restart
  # the unit.
  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = "/etc/cloudflared/${tunnelId}.json";
      default = "http_status:404";
      ingress = {
        ${publicFqdn} = "http://127.0.0.1:8334";
      };
    };
  };

  # Daily encrypted backup of Nextcloud data (files + nightly DB dump) to B2.
  # The DB dump is produced on the nextcloud host's nextcloud-db-backup timer
  # at 03:00 into /mnt/storage/nextcloud/.db-backup/, so this fires at 04:00
  # to ensure the dump is captured in the same snapshot.
  #
  # Backing up here (where the files live) avoids pulling all Nextcloud data
  # back over NFS just to ship it offsite.
  #
  # Secrets at /etc/restic/{password,b2.env}, same format as on vaultwarden.
  services.restic.backups.nextcloud = {
    paths = [ "/mnt/storage/nextcloud" ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/nextcloud";
    passwordFile = "/etc/restic/password";
    environmentFile = "/etc/restic/b2.env";
    initialize = true;
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 12"
    ];
  };

  # Same pattern as nextcloud: the immich host dumps its Postgres DB into
  # /mnt/storage/immich/.db-backup/ at 03:00, and this picks it up an hour
  # later alongside the originals + ML data. Photo libraries can grow large
  # — keep an eye on B2 spend; tighten pruneOpts if cost becomes an issue.
  services.restic.backups.immich = {
    paths = [ "/mnt/storage/immich" ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/immich";
    passwordFile = "/etc/restic/password";
    environmentFile = "/etc/restic/b2.env";
    initialize = true;
    timerConfig = {
      OnCalendar = "*-*-* 04:30:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 12"
    ];
  };

  # Daily encrypted backup of filebrowser state (BoltDB at
  # /var/lib/filebrowser/database.db, which holds the admin user record
  # and all generated share links). Reuses the restic password + B2
  # env file already in place for the nextcloud/immich backups.
  services.restic.backups.filebrowser = {
    paths = [ "/var/lib/filebrowser" ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/filebrowser";
    passwordFile = "/etc/restic/password";
    environmentFile = "/etc/restic/b2.env";
    initialize = true;
    timerConfig = {
      OnCalendar = "*-*-* 05:00:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 12"
    ];
  };

  # ntfy failure notifications. putio-sync is warn-tier (a missed sync run
  # corrects itself on the next 15-minute tick). Restic failures are
  # critical — a silent backup gap is the worst-case homelab failure mode.
  systemd.services."ntfy-failed-putio-sync" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "nas: putio-sync failed";
    } "putio-sync.service";
  systemd.services.putio-sync.onFailure = [ "ntfy-failed-putio-sync.service" ];

  systemd.services."ntfy-failed-restic-nextcloud" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "nas: restic nextcloud backup failed";
    } "restic-backups-nextcloud.service";
  systemd.services.restic-backups-nextcloud.onFailure = [ "ntfy-failed-restic-nextcloud.service" ];

  systemd.services."ntfy-failed-restic-immich" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "nas: restic immich backup failed";
    } "restic-backups-immich.service";
  systemd.services.restic-backups-immich.onFailure = [ "ntfy-failed-restic-immich.service" ];

  systemd.services."ntfy-failed-restic-filebrowser" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "nas: restic filebrowser backup failed";
    } "restic-backups-filebrowser.service";
  systemd.services.restic-backups-filebrowser.onFailure = [ "ntfy-failed-restic-filebrowser.service" ];

  # cloudflared tunnel failure is warn-tier: the public filebrowser path goes
  # down but LAN Samba/Jellyfin/NFS keep working.
  systemd.services."ntfy-failed-cloudflared" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "nas: cloudflared tunnel failed";
    } "cloudflared-tunnel-${tunnelId}.service";
  systemd.services."cloudflared-tunnel-${tunnelId}".onFailure = [ "ntfy-failed-cloudflared.service" ];

  system.stateVersion = "25.11";
}
