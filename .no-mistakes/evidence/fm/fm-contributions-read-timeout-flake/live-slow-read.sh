#!/usr/bin/env bash
# Live driver: real `fm-contributions.sh poll` against a gh stub that really
# sleeps past the 5s per-read cap (no faked exit codes). SCRIPT_ROOT selects
# which checkout's bin/ is exercised (fixed HEAD or base commit).
E=$(dirname "$0")
. "$E/helpers.sh"
SCRIPT_ROOT=${SCRIPT_ROOT:-$ROOT}
slow_forge() { # home: pulls/8 sleeps 7s on the calls listed in $FORGE/slow_calls (1-based)
  local home=$1
  mv "$home/fakebin/gh" "$home/fakebin/gh-fixture"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(/bin/date +%s)" "$*" >> "$FORGE/calls"
if [ "$*" = 'api repos/o/r/pulls/8' ]; then
  n=$(( $(cat "$FORGE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FORGE/n"
  if grep -qx "$n" "$FORGE/slow_calls" 2>/dev/null; then sleep 7; fi
fi
exec "$(dirname "$0")/gh-fixture" "$@"
SH
  chmod +x "$home/fakebin/gh"
}
poll() { # home label
  local out rc=0 t0 t1
  t0=$(/bin/date +%s)
  out=$(with_home "$1" "$SCRIPT_ROOT/bin/fm-contributions.sh" poll) || rc=$?
  t1=$(/bin/date +%s)
  echo "[$2] rc=$rc elapsed=$((t1-t0))s stdout=${out:-<none>}"
  echo "[$2] record.error=$(jq -c '.records[0].error' "$1/data/delivery/contributions.json")"
  echo "[$2] pulls/8 reads so far=$(grep -c ' api repos/o/r/pulls/8$' "$1/forge/calls")"
}
echo "== Scenario A: one transiently slow read (7s real sleep) on a healthy PR"
h=$(new_home live-once); forge_home "$h"; slow_forge "$h"; printf '1\n' > "$h/forge/slow_calls"
poll "$h" A
echo "== Scenario B: flapping - first read of every poll slow, 3 consecutive polls"
h=$(new_home live-flap); forge_home "$h"; slow_forge "$h"; printf '1\n3\n5\n' > "$h/forge/slow_calls"
for i in 1 2 3; do mutate_record "$h" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'; poll "$h" "B$i"; done
echo "== Scenario C: read is persistently slow (both attempts time out)"
h=$(new_home live-persist); forge_home "$h"; slow_forge "$h"; printf '1\n2\n3\n4\n' > "$h/forge/slow_calls"
poll "$h" C
echo "== Scenario D: slow read with only a small budget left (FM_CONTRIBUTIONS_BUDGET=3)"
h=$(new_home live-budget); forge_home "$h"; slow_forge "$h"; printf '1\n2\n' > "$h/forge/slow_calls"
mutate_record "$h" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
cp "$h/data/delivery/contributions.json" "$h/prior.json"
out=$(with_home "$h" env FM_CONTRIBUTIONS_BUDGET=3 "$SCRIPT_ROOT/bin/fm-contributions.sh" poll); echo "[D] stdout=${out:-<none>}"
cmp -s "$h/prior.json" "$h/data/delivery/contributions.json" && echo "[D] prior record kept unchanged" || echo "[D] record rewritten: $(cat "$h/data/delivery/contributions.json")"
echo "[D] pulls/8 reads=$(grep -c ' api repos/o/r/pulls/8$' "$h/forge/calls")"
