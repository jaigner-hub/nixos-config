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
# Keep IN SYNC with the Ansible side (keygrip: group_vars/appservers/vars.yml): cluster token, member
# list, the isolated ports, and the relaxed WAN timeouts. Addresses are tailnet IPs.
#
# Prereqs: monitor is tag:keygrip on the tailnet, and the tailnet ACL allows tag:keygrip <-> tag:keygrip
# on 2381,2382 (in addition to the dev cluster's 2379,2380). To enable: add this to the imports in
# this dir's configuration.nix, then deploy (scripts/deploy.sh monitor).
{ pkgs, ... }:
{
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 2381 2382 ];

  systemd.services.etcd-keygrip-app = {
    description = "etcd witness — keygrip appservers HA Postgres cluster (vote-only, isolated)";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
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
    };
    serviceConfig = {
      ExecStart = "${pkgs.etcd}/bin/etcd";
      Restart = "on-failure";
      RestartSec = "5";
      StateDirectory = "etcd-keygrip-app";   # creates/owns /var/lib/etcd-keygrip-app
      DynamicUser = true;
      LimitNOFILE = 65536;
    };
  };
}
