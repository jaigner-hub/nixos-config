# etcd WITNESS for the keygrip APPSERVERS HA Postgres cluster (keygrip1 + keygrip2).
#
# A SECOND, independent etcd witness alongside ./keygrip-etcd-witness.nix (the vent.dog cluster).
# Vote-only 3rd member: holds no Postgres, never promotable; makes failover safe on the two-data-node
# appservers cluster. Fully isolated from the dev witness so they never collide on this one box:
#   - ports     : 2381/2382   (dev witness uses 2379/2380)
#   - data dir  : /var/lib/etcd-keygrip-app
#   - token     : keygrip-app-pgha
#   - member    : monitor-app
# services.etcd is single-instance (the dev witness owns it), so this runs as a custom systemd unit.
#
# Keep IN SYNC with the Ansible side (keygrip: group_vars/appservers/vars.yml + the postgres_ha role
# defaults): cluster token, member list, the isolated ports, the relaxed WAN timeouts, and the
# auto-compaction settings. Addresses are tailnet IPs.
#
# Prereqs: monitor is tag:keygrip on the tailnet, and the tailnet ACL allows tag:keygrip <-> tag:keygrip
# on 2381,2382 (in addition to the dev cluster's 2379,2380). To enable: add this to the imports in
# this dir's configuration.nix, then deploy (scripts/deploy.sh monitor).
{ pkgs, ... }:
{
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 2381 2382 ];

  systemd.services.etcd-keygrip-app = {
    description = "etcd witness — keygrip appservers HA Postgres cluster (vote-only, isolated)";
    # wait-for-tailnet-ip: this unit binds 100.109.229.12 explicitly, and
    # tailscaled being active does NOT mean the address is on tailscale0 yet.
    # Without the gate the first start at boot dies with `bind: cannot assign
    # requested address` (observed 2026-07-29) and the witness vote only returns
    # on the 5s restart. `wants`, not `requires` — see common/wait-for-tailnet-ip.nix.
    after = [ "network-online.target" "tailscaled.service" "wait-for-tailnet-ip.service" ];
    wants = [ "network-online.target" "wait-for-tailnet-ip.service" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      ETCD_NAME = "monitor-app";
      ETCD_DATA_DIR = "/var/lib/etcd-keygrip-app";
      ETCD_INITIAL_CLUSTER_TOKEN = "keygrip-app-pgha";
      ETCD_INITIAL_CLUSTER_STATE = "new";
      ETCD_INITIAL_CLUSTER =
        "keygrip1=http://100.66.16.107:2382,keygrip2=http://100.126.169.25:2382,monitor-app=http://100.109.229.12:2382";
      ETCD_INITIAL_ADVERTISE_PEER_URLS = "http://100.109.229.12:2382";
      ETCD_LISTEN_PEER_URLS = "http://100.109.229.12:2382";
      ETCD_ADVERTISE_CLIENT_URLS = "http://100.109.229.12:2381";
      ETCD_LISTEN_CLIENT_URLS = "http://100.109.229.12:2381,http://127.0.0.1:2381";
      ETCD_HEARTBEAT_INTERVAL = "250";   # == etcd_heartbeat_ms
      ETCD_ELECTION_TIMEOUT = "2500";    # == etcd_election_ms
      ETCD_ENABLE_V2 = "false";
      # Discard revision history older than 1h. WITHOUT this, etcd keeps every
      # revision forever: on 2026-07-27 this cluster was found at 749 MB of its
      # 2 GiB quota, ~7 weeks from NOSPACE — at which point etcd goes read-only,
      # Patroni cannot refresh the leader lock, and BOTH the keygrip and keycloak
      # databases go down. Compaction is per-member, so the witness needs it in
      # its own config; the pair gets the same values from the Ansible side.
      # == etcd_auto_compaction_mode / etcd_auto_compaction_retention
      ETCD_AUTO_COMPACTION_MODE = "periodic";
      ETCD_AUTO_COMPACTION_RETENTION = "1h";
    };
    serviceConfig = {
      # PIN THE MINOR to match the pair. The two data nodes run the etcd image
      # pinned in the keygrip repo (postgres_ha role: quay.io/coreos/etcd:v3.5.16),
      # so `pkgs.etcd` — an unpinned nixpkgs-unstable follow — silently drifted
      # this witness to 3.6.13 (found 2026-07-29: cluster running mixed 3.6/3.5
      # with the cluster version held at 3.5.0). etcd supports at most ONE minor
      # of skew, and only transiently during a rolling upgrade; the next nixpkgs
      # bump would have put the witness two minors ahead, which is unsupported
      # and would break it with no change on our side. Bump this deliberately,
      # together with etcd_image in the keygrip repo — never by flake update.
      ExecStart = "${pkgs.etcd_3_5}/bin/etcd";
      Restart = "on-failure";
      RestartSec = "5";
      StateDirectory = "etcd-keygrip-app";   # creates/owns /var/lib/etcd-keygrip-app
      DynamicUser = true;
      LimitNOFILE = 65536;
    };
  };
}
