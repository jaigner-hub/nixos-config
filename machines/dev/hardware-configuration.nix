# Real hardware config for the dev VM (captured via nixos-generate-config on
# 10.0.0.57). Unlike the generic by-label placeholders on other hosts, this is
# pinned to dev's actual partition UUIDs, so `nixos-rebuild build-vm .#dev`
# won't work — regenerate this file if the VM's disk is ever recreated.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/profiles/qemu-guest.nix")
    ];

  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/16848dea-65ee-4b8c-9d71-4df779e021fc";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/711D-40F3";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/656c438f-01c9-4b69-b79f-a696f3bdd349"; }
    ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
