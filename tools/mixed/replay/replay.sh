#!/usr/bin/env bash
# Plays one recorded game (make_game.swift's actions) on 2048 Lab in a fresh
# simulator leased from simpool, through the simulator's own touch input, with
# one engine; then copies the app's stats (and crossing counts, if COUNT=1 was
# given) and a picture of the final board.
#
#   replay.sh <mixed|mixed-thread|webview> <2048 Lab .app> <game.json> <out dir> [KEY=VALUE…]
#
# KEY=VALUE pairs go into the app's environment (COUNT=1: MixedEngine counts
# its crossings, for split/grow_set.py). Needs SIMPOOL_URL/SIMPOOL_TOKEN (or
# simpool's defaults) and a profile named by SIMPOOL_PROFILE (default "air").
set -euo pipefail
S=${SIMPOOL:-simpool}
ENGINE=$1 APP=$2 GAME=$3 OUT=$4
shift 4
ENVS=()
for e in "$@"; do ENVS+=(-e "$e"); done
BUNDLE=com.LoganShire.IsomerMixedBench
mkdir -p "$OUT"
export SIMPOOL_LEASE=$($S lease --profile "${SIMPOOL_PROFILE:-air}" --ttl 900 --label "2048 Lab $ENGINE")
trap '$S release >/dev/null 2>&1 || true' EXIT
$S install "$APP" >/dev/null
$S launch ${ENVS[@]+"${ENVS[@]}"} "$BUNDLE" -- -play "$ENGINE" >/dev/null
# The engine starts and draws its first frame.
sleep 5
start=$(date +%s)
$S input - < "$GAME" >/dev/null
echo "$ENGINE: played in $(( $(date +%s) - start )) s"
# The stats are saved every 3 s.
sleep 5
$S screenshot "$OUT/$ENGINE-end.png" >/dev/null
for f in $($S files ls -b "$BUNDLE" Documents | grep -oE 'play-[A-Za-z0-9:._-]+'); do
  $S files get -b "$BUNDLE" "Documents/$f" "$OUT/$f" >/dev/null
done
$S terminate "$BUNDLE" >/dev/null || true
ls "$OUT"
