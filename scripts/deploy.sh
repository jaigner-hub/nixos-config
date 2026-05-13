#!/usr/bin/env bash
# Deploy the NixOS flake to online hosts via colmena.
#
# Usage:
#   scripts/deploy.sh                  # detect reachable hosts and deploy to those
#   scripts/deploy.sh adguard nas      # deploy to specific hosts (directory names)
set -euo pipefail

cd "$(dirname "$0")/.."

# Mirrors flake.nix:targetHostFor — directory name → ssh hostname.
declare -A SSH_TARGET=(
  [adguard]=adguard
  [dev]=dev
  [fragrance-app]=fragrance-app
  [gateway]=gateway
  [monitor]=monitor
  [nas]=nass
  [nextcloud]=nextcloud
  [vaultwarden]=vaultwarden
)

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set/p' "$0" | sed 's/^# \{0,1\}//; /^set/d'
    exit 0
    ;;
esac

if [ $# -gt 0 ]; then
  targets=("$@")
else
  echo "Probing hosts..."
  targets=()
  for h in "${!SSH_TARGET[@]}"; do
    if ssh -o ConnectTimeout=3 -o BatchMode=yes "jeff@${SSH_TARGET[$h]}" true 2>/dev/null; then
      targets+=("$h")
      echo "  ✓ $h"
    else
      echo "  ✗ $h (offline)"
    fi
  done
fi

if [ ${#targets[@]} -eq 0 ]; then
  echo "No reachable hosts. Aborting."
  exit 1
fi

on=$(IFS=,; echo "${targets[*]}")
echo
echo "Deploying to: $on"
echo

extra=()
if ! git diff --quiet HEAD -- 2>/dev/null || [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "  (working tree dirty — passing --impure to colmena)"
  echo
  extra+=(--impure)
fi

exec nix run nixpkgs#colmena -- "${extra[@]}" apply --on "$on"
