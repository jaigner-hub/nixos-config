# stash WITNESS — vote-only 3rd member of the stash secrets-manager cluster
# (~/Projects/stash). Mirrors the etcd witness (keygrip-etcd-witness.nix): it
# holds NO unseal key, so it is SEALED — it replicates only ciphertext, can
# never read a secret, and if it ever wins a leader election it immediately
# hands leadership back to a keyed node (vent.dog / vent.dog2). Its vote only
# matters when exactly one keyed box is down.
#
# State (CA, cluster.json, raft logs) lives in /var/lib/stash and is populated
# by a ONE-TIME join before the first deploy:
#
#   sudo /opt/stash/stash join <token> --no-key -data /var/lib/stash \
#        -node-id monitor -listen 100.109.229.12:8200 -raft-port 8300
#
# The service then just runs `stash server`, recovering identity + TLS material
# from /var/lib/stash. The static Go binary is placed at /opt/stash/stash.
# (Proper follow-up: package via buildGoModule instead of a placed binary.)
#
# tailscale0 is trusted via common/base.nix (all ports open), so the API (8200)
# and raft (8300) need no extra firewall rules. To enable: add
# ./stash-witness.nix to the imports in this dir's configuration.nix, then
# deploy (scripts/deploy.sh monitor).
{ ... }:
{
  systemd.tmpfiles.rules = [ "d /var/lib/stash 0700 root root -" ];

  systemd.services.stash-witness = {
    description = "stash secrets-manager witness (vote-only, sealed)";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "/opt/stash/stash server -data /var/lib/stash";
      Restart = "on-failure";
      RestartSec = "5";
      LimitNOFILE = 65536;
    };
  };
}
