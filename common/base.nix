{ config, pkgs, claude-code-nix, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

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

  services.tailscale.enable = true;
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
    unzip
    lsof
    tcpdump
    dnsutils
    nmap
    screen
    claude-code-nix.packages.${pkgs.system}.default
  ];

  system.autoUpgrade.enable = true;

  virtualisation.vmVariant = {
    services.getty.autologinUser = "root";
    users.users.root.password = "";
  };
}
