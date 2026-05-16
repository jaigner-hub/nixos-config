{ config, lib, pkgs, ... }:

let
  ntfyUrl = "https://nass.tail1ec6c3.ts.net";

  # POSTs $3 to ntfy topic $1 with title $2, using the writer token at
  # /etc/ntfy-token. Fails-silent on network/curl errors so a missing token
  # or down ntfy server doesn't cascade into more unit failures.
  ntfy-notify = pkgs.writeShellScriptBin "ntfy-notify" ''
    set -euo pipefail
    topic="$1"; title="$2"; body="$3"
    if [ ! -r /etc/ntfy-token ]; then
      echo "ntfy-notify: /etc/ntfy-token missing or unreadable; skipping" >&2
      exit 0
    fi
    token=$(cat /etc/ntfy-token)
    ${pkgs.curl}/bin/curl -sS --max-time 10 \
      -H "Authorization: Bearer $token" \
      -H "Title: $title" \
      -d "$body" \
      "${ntfyUrl}/$topic" || \
      echo "ntfy-notify: publish to $topic failed" >&2
  '';

  # Returns a systemd oneshot service definition that calls ntfy-notify with
  # the given topic/title and a body containing the last 20 lines of
  # `systemctl status` for the failing unit. Use as the OnFailure= target.
  mkOnFailure = { topic, title }: unitName: {
    description = "ntfy notification for ${unitName} failure";
    serviceConfig.Type = "oneshot";
    script = ''
      ${ntfy-notify}/bin/ntfy-notify ${topic} "${title}" \
        "$(${pkgs.systemd}/bin/systemctl status --no-pager --lines=20 ${unitName} || true)"
    '';
  };
in {
  environment.systemPackages = [ ntfy-notify ];

  # nixos-upgrade.service exists on every host via common/base.nix's
  # system.autoUpgrade block. Wire it here so all hosts get coverage
  # without each one repeating the pattern.
  systemd.services."ntfy-failed-nixos-upgrade" =
    mkOnFailure {
      topic = "homelab-warn";
      title = "${config.networking.hostName}: nixos-upgrade failed";
    } "nixos-upgrade.service";
  systemd.services.nixos-upgrade.onFailure = [ "ntfy-failed-nixos-upgrade.service" ];

  # Expose the helper to per-host configs via _module.args so they can wire
  # their own service-specific failures (e.g. restic, putio-sync, db-backup).
  _module.args.mkNtfyOnFailure = mkOnFailure;
}
