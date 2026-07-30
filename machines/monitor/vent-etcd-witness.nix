# etcd WITNESS for the HA Postgres cluster on the VENT.DOG PAIR (vent.dog + vent.dog2).
#
# This is the vote-only 3rd etcd member. It holds NO Postgres and is never promotable — it exists so
# automatic failover is safe on a two-data-node cluster. Those two IONOS boxes form a 2/3 majority on
# their own; this vote only matters when exactly one of them is down. So a transient `monitor` reboot
# (power blip) while both boxes are healthy is a non-event.
#
# ⚠️ RENAMED 2026-07-29 from `keygrip-etcd-witness.nix`, which had become actively misleading. This
# WAS keygrip's dev cluster, back when keygrip dev lived on the IONOS pair. It is not any more: the
# keygrip rebuild moved to the keygrip1 + keygrip2 tier, and the keygrip repo dropped these two boxes
# from its inventory on 2026-07-23 (they now host the separate Vent chat project). The cluster this
# file votes in serves the VENT pair, whatever still runs there.
#
# ⚠️ DO NOT "keep this in sync" with keygrip's ansible/roles/postgres_ha/defaults/main.yml, as the
# old header told you to. That role now describes the keygrip1 + keygrip2 cluster (ADR 0016) — whose
# witness is the SIBLING module ./keygrip-app-etcd-witness.nix, on isolated ports 2381/2382. Copying
# that role's member list or token into this file would break THIS cluster's membership.
#
# ⚠️ The `keygrip-pgha` token and the `/var/lib/etcd-keygrip` dataDir keep their misleading names ON
# PURPOSE: the token is part of this live cluster's identity and the dataDir holds its raft state, so
# renaming either is a cluster break / data orphan, not a cosmetic edit. Only the FILE was renamed.
#
# Prereqs: `monitor` is on the tailnet as tag:keygrip, and the tailnet ACL allows
# tag:keygrip <-> tag:keygrip on 2379,2380. Addresses are tailnet IPs (MagicDNS isn't relied on).
#
# To enable: add `./vent-etcd-witness.nix` to the `imports` list in this dir's
# configuration.nix, then `nixos-rebuild switch` (or your colmena/flake apply) on monitor.
{ pkgs, ... }:
{
  # etcd peer (2380) + client (2379) — TAILNET ONLY.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 2379 2380 ];

  services.etcd = {
    enable = true;
    name = "monitor";
    dataDir = "/var/lib/etcd-keygrip";

    # PIN THE MINOR to match the two data nodes. `services.etcd` defaults to
    # `pkgs.etcd`, an unpinned nixpkgs-unstable follow, which had silently
    # carried this witness to 3.6.13 while vent.dog and vent.dog2 both sit on
    # 3.5.16 (measured 2026-07-29; cluster version and storage version were both
    # still 3.5.0, which is the only reason the mixed cluster was working). etcd
    # tolerates ONE minor of skew, and only transiently during a rolling
    # upgrade — the next nixpkgs bump would have put this member two minors
    # ahead of the pair, which is unsupported, with no change on our side to
    # blame. Same pin as the keygrip witness in ./keygrip-app-etcd-witness.nix.
    # Bump deliberately, alongside the pair — never via `nix flake update`.
    package = pkgs.etcd_3_5;

    initialClusterToken = "keygrip-pgha";          # == pg_ha_etcd_token
    initialClusterState = "new";
    initialCluster = [
      "vent-keygrip=http://100.106.141.112:2380"
      "vent-keygrip2=http://100.110.200.36:2380"
      "monitor=http://100.109.229.12:2380"
    ];

    # Bind + advertise on monitor's TAILNET IP (100.109.229.12) — never the LAN/WAN interface.
    initialAdvertisePeerUrls = [ "http://100.109.229.12:2380" ];
    listenPeerUrls          = [ "http://100.109.229.12:2380" ];
    advertiseClientUrls     = [ "http://100.109.229.12:2379" ];
    listenClientUrls        = [ "http://100.109.229.12:2379" "http://127.0.0.1:2379" ];

    # Relaxed for the WAN/Tailscale hop — MUST match etcd_heartbeat_ms / etcd_election_ms.
    extraConf = {
      HEARTBEAT_INTERVAL = "250";
      ELECTION_TIMEOUT   = "2500";
      ENABLE_V2          = "false";
    };
  };
}
