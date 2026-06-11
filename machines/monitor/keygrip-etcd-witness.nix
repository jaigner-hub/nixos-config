# etcd WITNESS for the keygrip HA Postgres cluster (ADR 0016 in ~/Projects/keygrip).
#
# This is the vote-only 3rd etcd member. It holds NO Postgres and is never promotable — it exists so
# automatic failover is safe on a two-data-node cluster (vent.dog + vent.dog2). Those two IONOS boxes
# form a 2/3 majority on their own; this vote only matters when exactly one of them is down. So a
# transient `monitor` reboot (power blip) while both boxes are healthy is a non-event.
#
# Keep these IN SYNC with the Ansible side (keygrip: ansible/roles/postgres_ha/defaults/main.yml):
#   cluster token, the member list, and the relaxed WAN timeouts.
#
# Prereqs: `monitor` is on the tailnet as tag:keygrip, and the tailnet ACL allows
# tag:keygrip <-> tag:keygrip on 2379,2380. Addresses are tailnet IPs (MagicDNS isn't relied on).
#
# To enable: add `./keygrip-etcd-witness.nix` to the `imports` list in this dir's
# configuration.nix, then `nixos-rebuild switch` (or your colmena/flake apply) on monitor.
{ ... }:
{
  # etcd peer (2380) + client (2379) — TAILNET ONLY.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 2379 2380 ];

  services.etcd = {
    enable = true;
    name = "monitor";
    dataDir = "/var/lib/etcd-keygrip";

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
