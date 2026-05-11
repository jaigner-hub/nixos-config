#!/usr/bin/env bash
# Post-clone bootstrap: prepares a freshly-cloned (or freshly-installed)
# NixOS VM to become a distinct host in this flake.
#
# Resets per-machine identity (machine-id, SSH host keys), regenerates
# hardware-configuration.nix for the actual disks, then rebuilds with the
# target host config.
#
# Usage: sudo ./scripts/post-clone-bootstrap.sh <host>

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root (try: sudo $0 $*)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-}"

if [[ -z "$HOST" ]]; then
  echo "Usage: sudo $0 <host>" >&2
  echo "Available hosts: $(ls "$REPO_ROOT/machines" | tr '\n' ' ')" >&2
  exit 1
fi

HOST_DIR="$REPO_ROOT/machines/$HOST"
if [[ ! -d "$HOST_DIR" ]]; then
  echo "Unknown host '$HOST' — no directory at $HOST_DIR" >&2
  exit 1
fi

echo "==> Resetting /etc/machine-id"
rm -f /etc/machine-id
systemd-machine-id-setup

echo "==> Regenerating SSH host keys"
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A

echo "==> Writing fresh hardware-configuration.nix for $HOST"
nixos-generate-config --show-hardware-config > "$HOST_DIR/hardware-configuration.nix"

echo "==> Rebuilding as $HOST"
nixos-rebuild switch --flake "$REPO_ROOT#$HOST"

cat <<EOF

Done.

The regenerated hardware-configuration.nix at:
  $HOST_DIR/hardware-configuration.nix

is per-machine local state — DO NOT commit it. The committed placeholder
must stay generic so 'nixos-rebuild build-vm' works across hosts.

Reboot recommended to fully apply the hostname change.
EOF
