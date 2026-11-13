#!/bin/bash
# Fake-Steam lobby scenarios, 3 players (logs in $TMPDIR/foolsrules_fl). $1 = scenario: full | guest_drop | rejoin | host_leaves | kick | drift
cd "$(dirname "$0")/../.."
D="${TMPDIR:-/tmp}/foolsrules_fl"
mkdir -p "$D"; rm -f "$D"/*.log "$D"/code.txt
P="godot --headless --path . --script res://scripts/tests/fake_lobby_player.gd --"
C="--code-file=$D/code.txt --players=3 --net-trace"
timeout 130 godot --headless --path . --script res://scripts/tests/fake_steam_server.gd -- --fake-steam-idle=8 > "$D/server.log" 2>&1 &
sleep 1
HOST_EXTRA=""; G2_EXTRA=""; G1_EXTRA=""
case "$1" in
  guest_drop|rejoin) G2_EXTRA="--lan-quit-after=3" ;;
  host_leaves) HOST_EXTRA="--lan-quit-after=3" ;;
  kick) HOST_EXTRA="--kick-seat=2" ;;
  drift) G1_EXTRA="--desync-at=20" ;;
esac
timeout 120 $P --fake-steam=1 --role=host --seat=0 $C $HOST_EXTRA > "$D/host.log" 2>&1 &
sleep 1
timeout 120 $P --fake-steam=2 --role=join --seat=1 $C $G1_EXTRA > "$D/g1.log" 2>&1 &
timeout 120 $P --fake-steam=3 --role=join --seat=2 $C $G2_EXTRA > "$D/g2.log" 2>&1 &
G2=$!
if [ "$1" = "rejoin" ]; then
  wait $G2; sleep 0.5
  timeout 110 $P --fake-steam=3 --role=rejoin --seat=2 $C > "$D/g2b.log" 2>&1 &
fi
if [ "$1" = "kick" ]; then
  wait $G2; sleep 1   # kicked guest 2 is out: a fresh seat-2 player takes the place
  timeout 110 $P --fake-steam=4 --role=join --seat=2 $C > "$D/g3.log" 2>&1 &
fi
wait
for f in server host g1 g2 g2b g3; do
  [ -f "$D/$f.log" ] || continue
  echo "== $f ($(grep -ac 'SCRIPT ERROR' "$D/$f.log") script errors)"
  grep -aE "\[player\]|\[fake steam\]|game over|DESYNC|\[net\]|walking out|SCRIPT ERROR" "$D/$f.log" | grep -av "^\s*at:" | head -12
done
