{ pkgs }:

# Prebuilt DLL fetched from the upstream GitHub release. Pinned by hash —
# bumping `version` requires updating `hash` (Nix prints the expected value
# on rebuild). Source: https://github.com/jaigner-hub/jellyfin-sleep-timer
pkgs.stdenvNoCC.mkDerivation rec {
  pname = "jellyfin-plugin-sleeptimer";
  version = "1.1.0";

  src = pkgs.fetchurl {
    url = "https://github.com/jaigner-hub/jellyfin-sleep-timer/releases/download/v${version}/SleepTimer_v${version}.zip";
    hash = "sha256-/oNYskheWAp5OQ2VY16jTF/lf2gxCrOM2BoEXgiV56Y=";
  };

  nativeBuildInputs = [ pkgs.unzip ];

  unpackPhase = ''
    runHook preUnpack
    unzip $src
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 Jellyfin.Plugin.SleepTimer.dll $out/lib/Jellyfin.Plugin.SleepTimer.dll
    runHook postInstall
  '';

  # Intentionally not installing meta.json: Jellyfin's PluginManager
  # writes back to it (state tracking), so it can't live in the read-only
  # Nix store. The plugin dir is owned by jellyfin:jellyfin 0700, so
  # Jellyfin generates a fresh meta.json there on first load.

  meta = {
    description = "Jellyfin server-side sleep timer plugin";
    homepage = "https://github.com/jaigner-hub/jellyfin-sleep-timer";
    platforms = pkgs.lib.platforms.linux;
  };
}
