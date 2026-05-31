{ config, pkgs, claude-code-nix, hostKey, ... }:

{
  imports = [ ./ntfy-notify.nix ./wait-for-magicdns.nix ./disk-health-monitor.nix ./alloy.nix ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "root" "jeff" ];

  # Keep the Nix store from filling these small (28G) root disks. Frequent
  # deploys pile up generations fast; weekly GC drops anything older than a
  # week, and auto-optimise hardlink-dedups identical files on every build.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nix.settings.auto-optimise-store = true;

  # Weekly TRIM so blocks freed inside the guest are released back to the
  # hypervisor's local-lvm thin pool. The QEMU disks are configured with
  # discard=on (set on the Proxmox host, not here); without periodic fstrim the
  # over-provisioned pool only ever grows and eventually hits 100%, at which
  # point dm-thin errors all writes and every VM freezes with I/O errors — this
  # took down the whole fleet on 2026-05-25.
  services.fstrim.enable = true;

  # Passwordless wheel so `colmena apply` can activate non-interactively.
  # Access is gated by key-only SSH + tailscale-only firewall.
  security.sudo.wheelNeedsPassword = false;

  time.timeZone = "America/Chicago";

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  networking.networkmanager.enable = true;
  # Comcast's DHCPv6 hands the same ::suffix to every VM on the Proxmox bridge
  # (no prefix delegation), so the kernel's Duplicate Address Detection sees a
  # sibling VM's identical address as a conflict and NetworkManager logs
  # `dhcp6 (ens18): DAD failed for address 2601:...` on every boot and lease
  # renewal — the single largest error source in Loki (100+ lines/boot/host).
  # Disable DAD on the interface so the address binds without the check. Don't
  # disable IPv6 entirely — tailscale negotiates v6 direct tunnels and yanking
  # v6 mid-flight leaves peers talking to dead endpoints (broke fleet
  # connectivity 2026-05-19).
  #
  # This MUST be the per-interface key. `default.accept_dad` only seeds
  # interfaces created *after* it is set, but ens18 already exists at boot with
  # the compiled-in default of 1, so all/default=0 never actually disabled DAD
  # on it. systemd re-applies per-interface sysctls via udev when the NIC
  # appears (before NM runs DHCPv6), so the address is added with DAD already
  # off. Every host is a Proxmox VM whose primary NIC is ens18.
  #
  # NB: there is no `ipv6.dad-timeout` NetworkManager connection property (only
  # ipv4 has one), so the previous [connection] default was silently dropped as
  # an "unknown key" and disabled nothing — verified in the NM logs fleet-wide.
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.accept_dad" = 0;
    "net.ipv6.conf.default.accept_dad" = 0;
    "net.ipv6.conf.ens18.accept_dad" = 0;
  };

  users.users.jeff = {
    isNormalUser = true;
    description = "Jeff";
    extraGroups = [ "networkmanager" "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCbsR0Io6NeA2anMEL5GbKZIBlLKDn9tafrPQJtPAO9EtIlkMKkYVm0wCLJzjiOZ4rgNW7p0C9OxZJ2DpkuK43GtVEePP+A9pvHJNKyVEzL9ZIO4r3F9JPkpvMpCxKTZaJ4K5Fid4fE/C7M9OzA+1kSNjrEGp/MQ8M2EP1KXsOf26pmubBsIYu4GYz4x1jOPhauFWq2XbWWzJQJeMKuDPWR7gTAkTq1w/Gb8ZsNXA6gpvPdPKXCGNYqDB5jZOeE2w8957z0yDznMc/LoF8WXczg5xVtj/X5/5FsOxYKQXIoZlww6CChTz/X5jgWySIUh6OvnSaYXVgB+kW/xLt4/dQYMFrdj73X2wwroVul5eSz67JEonvIdk6K7APFBYvyoRJL2Qw4R8M+86uDTMwQfyXjUoXJcCZKxRljypRmReMsHYFS6+PIsJsy4Wq0I+gt0VIARN9+xETRtogQOT0osrx+Oh7uuevyP6pbCwmr1HY/E4rq8zKyREV5FLm3NilNie8= jaigner@Jeffs-Laptop"
    ];
  };

  nixpkgs.config.allowUnfree = true;

  services.openssh.enable = true;

  # Mosh for resilient shells over roaming/flaky links (laptop suspend, phone
  # tethering). Opens UDP 60000-61000; the session key is still exchanged over
  # SSH first, so it's no more exposed than the already-open SSH port.
  programs.mosh.enable = true;

  services.qemuGuest.enable = true;

  services.resolved.enable = true;
  services.tailscale.enable = true;

  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = [ "systemd" "processes" ];
    port = 9100;
    listenAddress = "0.0.0.0";
  };
  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ config.services.tailscale.port ];
    checkReversePath = "loose";
  };

  programs.git = {
    enable = true;
    config = {
      credential.helper = "store";
    };
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    htop
    btop
    git
    tmux
    rsync
    tree
    bat
    unzip
    lsof
    tcpdump
    dnsutils
    nmap
    screen
    claude-code-nix.packages.${pkgs.system}.default
  ];

  # Pull-based auto-update from GitHub (source of truth). Each host fetches
  # the latest commit on `main` daily and switches. Uses `${hostKey}` (set in
  # flake.nix) rather than `networking.hostName` so the `nas` host (hostname
  # "nass") still resolves to the `nas` flake output.
  system.autoUpgrade = {
    enable = true;
    flake = "github:jaigner-hub/nixos-config#${hostKey}";
    randomizedDelaySec = "30min";
    allowReboot = false;
  };

  virtualisation.vmVariant = {
    services.getty.autologinUser = "root";
    users.users.root.password = "";
  };
}
