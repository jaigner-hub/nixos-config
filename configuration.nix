# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, claude-code-nix, ... }:
# python
let
  pythonWithPackages = pkgs.python3.withPackages (ps: with ps; [
    requests
  ]);
  # sync script
  syncScript = pkgs.writeScriptBin "putio-sync" (builtins.readFile ./putio-sync.py);
in
{
  imports =
    [ # Include the results of the hardware scan.
    ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nass"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "America/Chicago";

  # Select internationalisation properties.
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

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.jeff = {
    isNormalUser = true;
    description = "Jeff";
    extraGroups = [ "networkmanager" "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCbsR0Io6NeA2anMEL5GbKZIBlLKDn9tafrPQJtPAO9EtIlkMKkYVm0wCLJzjiOZ4rgNW7p0C9OxZJ2DpkuK43GtVEePP+A9pvHJNKyVEzL9ZIO4r3F9JPkpvMpCxKTZaJ4K5Fid4fE/C7M9OzA+1kSNjrEGp/MQ8M2EP1KXsOf26pmubBsIYu4GYz4x1jOPhauFWq2XbWWzJQJeMKuDPWR7gTAkTq1w/Gb8ZsNXA6gpvPdPKXCGNYqDB5jZOeE2w8957z0yDznMc/LoF8WXczg5xVtj/X5/5FsOxYKQXIoZlww6CChTz/X5jgWySIUh6OvnSaYXVgB+kW/xLt4/dQYMFrdj73X2wwroVul5eSz67JEonvIdk6K7APFBYvyoRJL2Qw4R8M+86uDTMwQfyXjUoXJcCZKxRljypRmReMsHYFS6+PIsJsy4Wq0I+gt0VIARN9+xETRtogQOT0osrx+Oh7uuevyP6pbCwmr1HY/E4rq8zKyREV5FLm3NilNie8= jaigner@Jeffs-Laptop"
    ];
    packages = with pkgs; [
    #  thunderbird
    ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
	vim
	wget
	curl
	htop
	iotop
	nmap
	git
	jellyfin
	samba
	mergerfs
	python3
	tmux
	claude-code-nix.packages.${pkgs.system}.default
	gcc
	gnumake
	gdb
	screen
	unixtools.netstat
	ffmpeg-full
	smartmontools
	hdparm
	parted
	ncdu
	rsync
	tree
	unzip
	p7zip
	lsof
	btop
	dnsutils
	tcpdump
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true; 

services.jellyfin = {
  enable = true;
  openFirewall = true;
};

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

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

  # enable automatic updates
  system.autoUpgrade.enable = true;


  # external HDD 1
  fileSystems."/mnt/hdd1" = {
    device = "/dev/disk/by-uuid/ca1567d9-3634-4e46-acd9-545d7525371b";
    fsType = "ext4";
    options = [ "nofail" ];
  };

  # external HDD 2
  fileSystems."/mnt/hdd2" = {
    device = "/dev/disk/by-uuid/f15c866f-d200-4b12-866f-bd36c79c626b";
    fsType = "ext4";
    options = [ "nofail" ];
  };

  # combined HDD filesystem using mergerfs
  fileSystems."/mnt/storage" = {
    device = "/mnt/hdd1:/mnt/hdd2";
    fsType = "fuse.mergerfs";
    options = [ "nofail" ];
  };

  # crontab
  systemd.services.putio-sync = {
    description = "put.io sync";
    serviceConfig = {
      ExecStart = "${pythonWithPackages}/bin/python3 ${syncScript}/bin/putio-sync";
      Type = "oneshot";
      EnvironmentFile = "/etc/putio-sync.env";
    };
  };

  systemd.timers.putio-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
    };
  };
}
