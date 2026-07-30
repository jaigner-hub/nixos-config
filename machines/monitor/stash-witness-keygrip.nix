# stash WITNESS — vote-only 3rd member of the KEYGRIP stash cluster (keygrip1 +
# keygrip2 keyed nodes, on the ~/Projects/keygrip appservers tier). A SECOND,
# independent witness alongside ./stash-witness.nix (the vent.dog cluster): it
# holds NO unseal key, so it is SEALED — replicates only ciphertext, can never
# read a secret, and hands leadership back to a keyed node if it ever wins an
# election. Its vote only matters when exactly one keyed box is down.
#
# Kept fully separate from the vent witness so the two clusters never collide:
#   - data dir : /var/lib/stash-keygrip   (vent witness uses /var/lib/stash)
#   - API/raft : 8201 / 8301              (vent witness uses 8200 / 8300)
#   - node-id  : monitor-keygrip          (vent witness is `monitor`)
# Both share the single binary at /opt/stash/stash.
#
# State (CA, cluster.json, raft logs) is populated by a ONE-TIME join before the
# first deploy:
#
#   sudo /opt/stash/stash join <token> --no-key -data /var/lib/stash-keygrip \
#        -node-id monitor-keygrip -listen 100.109.229.12:8201 -raft-port 8301
#
# The service then just runs `stash server`, recovering identity + TLS + ports
# from /var/lib/stash-keygrip/cluster.json.
#
# tailscale0 is trusted via common/base.nix (all ports open), so 8201/8301 need
# no extra firewall rules. To enable: add ./stash-witness-keygrip.nix to the
# imports in this dir's configuration.nix, then deploy (scripts/deploy.sh monitor).
{ ... }:
{
  systemd.tmpfiles.rules = [ "d /var/lib/stash-keygrip 0700 root root -" ];

  systemd.services.stash-witness-keygrip = {
    description = "stash secrets-manager witness — keygrip cluster (vote-only, sealed)";
    # wait-for-tailnet-ip: `stash server` recovers -listen 100.109.229.12:8201
    # from cluster.json and binds it explicitly, so it loses the same boot race
    # the etcd witness does — first start 2026-07-29 died with `bind: cannot
    # assign requested address`. `wants`, not `requires`: a failed gate must not
    # strand the witness, the restart loop is still the backstop.
    after = [ "network-online.target" "tailscaled.service" "wait-for-tailnet-ip.service" ];
    wants = [ "network-online.target" "wait-for-tailnet-ip.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "/opt/stash/stash server -data /var/lib/stash-keygrip";
      Restart = "on-failure";
      RestartSec = "5";
      LimitNOFILE = 65536;
    };
  };
}
