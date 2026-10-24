#!/bin/sh
# Card Fighters' Clash: SNK Version on machine A, Capcom Version on machine B.
#   wsl -e sh sim/link2/cfc.sh <script> [plusargs...]
# ROMS points at a folder holding the colour BIOS (ngpc.rom) and the two
# games; SNK and CAPCOM name the games' files inside it.
ROMS=${ROMS:?set ROMS to the folder with ngpc.rom and the two games}
SNK=${SNK:-"SNK vs. Capcom - Card Fighters' Clash - SNK Version (USA, Europe).ngp"}
CAPCOM=${CAPCOM:-"SNK vs. Capcom - Card Fighters' Clash - Capcom Version (USA, Europe).ngp"}
D="$(dirname "$0")"
S=$1; shift
case "$S" in /*) ;; *) S="$(cd "$D" && pwd)/scripts/$S" ;; esac
BUILD=${BUILD:-0} exec sh "$D/run_link2.sh" "$ROMS/ngpc.rom" \
	"$ROMS/$SNK" "$ROMS/$CAPCOM" "$S" "$@"
