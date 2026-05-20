{ config, lib, pkgs, ... }:

let
  alloyConfig = pkgs.writeText "config.alloy" ''
    // Ship systemd journal entries to Loki on monitor. The DynamicUser is
    // already in the systemd-journal group (set by the NixOS alloy module),
    // so no extra permissions needed.

    loki.relabel "journal" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }
      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "level"
      }
      rule {
        source_labels = ["__journal_syslog_identifier"]
        target_label  = "syslog_identifier"
      }
    }

    loki.source.journal "journal" {
      max_age       = "12h"
      relabel_rules = loki.relabel.journal.rules
      forward_to    = [loki.write.default.receiver]
      labels        = {
        job  = "systemd-journal",
        host = "${config.networking.hostName}",
      }
    }

    loki.write "default" {
      endpoint {
        url = "http://monitor:3100/loki/api/v1/push"
      }
    }
  '';
in
{
  environment.etc."alloy/config.alloy".source = alloyConfig;

  services.alloy = {
    enable = true;
    # extraFlags keeps Alloy's own diagnostics endpoint local — we don't need
    # to expose its HTTP API on the tailnet.
    extraFlags = [
      "--server.http.listen-addr=127.0.0.1:12345"
      "--disable-reporting"
    ];
  };
}
