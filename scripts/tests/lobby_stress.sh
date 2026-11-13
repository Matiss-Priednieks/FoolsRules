#!/bin/bash
# Pre-game lobby stress: host + 5 guests, random seats (clashes), random churn. $1 = rounds
# PASS = the host's game starts with all 6 players (no bots); the round stops right there.
cd "$(dirname "$0")/../.."
D="${TMPDIR:-/tmp}/foolsrules_st"
mkdir -p "$D"
P="godot --headless --path . --script res://scripts/tests/fake_lobby_player.gd --"
for r in $(seq 1 ${1:-3}); do
  rm -f "$D"/*.log "$D"/code.txt
  PIDS=""
  timeout 90 godot --headless --path . --script res://scripts/tests/fake_steam_server.gd -- --fake-steam-idle=5 > "$D/server.log" 2>&1 & PIDS="$PIDS $!"
  sleep 0.7
  T0=$(date +%s)
  timeout 80 $P --fake-steam=1 --role=host --players=6 --code-file=$D/code.txt --real-pregame > "$D/host.log" 2>&1 & PIDS="$PIDS $!"
  for g in 2 3 4 5 6; do
    sleep 0.$((RANDOM % 4))
    timeout 70 $P --fake-steam=$g --role=join --players=6 --seat=$((1 + RANDOM % 5)) --churn=$((RANDOM % 3)) \
      --code-file=$D/code.txt > "$D/g$g.log" 2>&1 & PIDS="$PIDS $!"
  done
  RES="FAIL - never started (60s)"
  for i in $(seq 1 300); do
    sleep 0.2
    L=$(grep -a "everyone ready, counting down" "$D/host.log" | head -1)
    if [ -n "$L" ]; then
      T=$(( $(date +%s) - T0 ))
      case "$L" in *"bots for []"*) RES="PASS - all 6 started in ~${T}s" ;; *) RES="FAIL - started with bots: ${L##*bots for }" ;; esac
      break
    fi
  done
  kill $PIDS 2>/dev/null; wait 2>/dev/null
  CLASH=$(cat "$D"/g*.log | grep -ac "taken, taking")
  CHURN=$(grep -ac "left 1" "$D/server.log")
  ERR=$(cat "$D"/*.log | grep -ac "SCRIPT ERROR")
  echo "round $r: $RES | seat clashes $CLASH, lobby leaves $CHURN, script errors $ERR"
done
