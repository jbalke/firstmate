#!/usr/bin/env bash
# End-user repro: one registered remote secondmate answers the structured
# home-summary probe with rc=0 and junk on stdout; a healthy one answers well.
# Runs `fm-fleet-snapshot.sh --json` and the human `fm-fleet-view.sh` renderer.
set -u
ROOT=${1:?repo root}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-evidence.XXXXXX")
home=$TMP/home
mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config" "$TMP/fakebin"
cat > "$TMP/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP/fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
host=; prev=
for arg in "$@"; do
  if [ "$prev" = "--" ]; then host=$arg; break; fi
  prev=$arg
done
case "$host" in
  junk-host)
    printf 'rc=0\n{"schema":"fm-secondmate-home-summary.v1"\n' ;;
  good-host)
    printf '%s\n' '{"schema":"fm-secondmate-home-summary.v1","generated":"2026-08-28T00:00:00Z","home":"/remote/good-home","valid":true,"reason":null,"invalidity":{"kind":null,"ids":[]},"state":"no_active_work","active_children":[],"decisions_open":[],"holds":[],"queued":[],"landed":[],"endpoints":[],"counts":{"active_children":0,"decisions_open":0,"holds":0,"queued":0,"landed":0,"endpoints":0},"omitted":[]}' ;;
esac
exit 0
SH
chmod +x "$TMP/fakebin/no-mistakes" "$TMP/fakebin/fake-ssh"
cat > "$home/data/secondmates.md" <<'EOF'
- good-mate - good remote (host: good-host; root: /remote/root; home: /remote/good-home; scope: remote testing; projects: alpha; added 2026-08-02)
- junk-mate - junk remote (host: junk-host; root: /remote/root; home: /remote/junk-home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF

run() { PATH="$TMP/fakebin:$PATH" FM_HOME="$home" FM_SSH_BIN="$TMP/fakebin/fake-ssh" "$@"; }

echo "\$ bin/fm-fleet-snapshot.sh --json   # (registered secondmate records)"
out=$(run "$ROOT/bin/fm-fleet-snapshot.sh" --json); rc=$?
echo "exit status: $rc"
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" | tail -5
else
  printf '%s' "$out" | jq '{records: [.secondmate_current.records[] | {id, home, state: .current.state, reason: .current.reason, selected: .provenance.selected}]}'
fi
echo
echo "\$ bin/fm-fleet-view.sh              # human renderer, secondmate section"
view=$(run "$ROOT/bin/fm-fleet-view.sh" 2>&1); vrc=$?
echo "exit status: $vrc"
printf '%s\n' "$view" | sed -n '/[Ss]econdmate/,$p' | head -20
rm -rf "$TMP"
