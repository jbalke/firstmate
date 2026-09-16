#!/usr/bin/env bash
# Live product driver for the Codex-snow doorbell fix on the CURSORLESS
# backend (herdr) - the backend the reported incident happened on.
#
# Stands bin/fm-send.sh up the way an operator runs it (isolated FM_HOME, real
# durable inbox, a REAL isolated herdr server via bin/fm-herdr-lab.sh) against a
# herdr pane whose screen is the real Codex snow capture, with a registered
# codex agent on it. Herdr's composer read is cursorless (cursor=0), so this
# exercises _fm_composer_select_cursorless, not the tmux cursor path.
#
# Usage: snow-doorbell-herdr-live.sh <clean|typed> <outdir>
set -u

ROOT=${ROOT:?}
MODE=$1
OUT=$2
mkdir -p "$OUT"
unset NO_MISTAKES_GATE

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not installed"; exit 0; }

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-snow-$$-$MODE"
export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-snow-herdr.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TYPED_LOG="$LAB/pane-stdin.log"
: > "$TYPED_LOG"

cleanup() {
  herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/bin" "$LAB/home/state"

FIXTURE="$ROOT/tests/fixtures/codex-snow-composer.ansi-escaped"
python3 - "$FIXTURE" "$MODE" > "$LAB/screen.ansi" <<'PYS'
import sys
raw = open(sys.argv[1]).read().rstrip("\n")
screen = raw.encode().decode("unicode_escape").encode("latin-1").decode("utf-8")
rows = screen.split("\r\n")
if sys.argv[2] == "typed":
    rows[3] = rows[3].replace("›", "›ship the scope cut ", 1)
sys.stdout.write("\r\n".join(rows))
PYS

cat > "$LAB/bin/codex" <<SH
#!/usr/bin/env bash
set -u
render() { printf '\033[2J\033[H'; cat "$LAB/screen.ansi"; }
render
while IFS= read -r line; do
  printf '%s\n' "\$line" >> "$TYPED_LOG"
  render
done
SH
chmod +x "$LAB/bin/codex"

fm_herdr_lab_prepare "$SESSION" >/dev/null || { echo "could not prepare isolated herdr lab"; exit 1; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { echo "fm_backend_source herdr failed"; exit 1; }

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$LAB") || { echo "container_ensure failed"; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED=${CONTAINER_RAW#*$'\t'}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-snow-$MODE" "$LAB" "$SEEDED") || { echo "create_task failed"; exit 1; }
read -r TAB_ID PANE_ID <<EOF
$IDS
EOF
TARGET="$SESSION:$PANE_ID"

# Run the codex stand-in with argv[0] = the codex path, so herdr's own pane
# process-state read classifies the pane's foreground process as an agent.
fm_backend_herdr_send_text_line "$TARGET" "exec -a '$LAB/bin/codex' bash '$LAB/bin/codex'"
sleep 2
# Register the agent the way herdr's own clients do, so the recovery-grade
# liveness probe reads this pane as a live codex agent.
herdr pane report-agent "$PANE_ID" --source fm-snow-live --agent codex --state idle \
  --session "$SESSION" >/dev/null 2>&1 || true
sleep 1

{
  printf 'mode=%s (backend=herdr, cursorless)\n' "$MODE"
  printf 'pane agent state : %s\n' "$(fm_backend_agent_state herdr "$TARGET")"
  printf 'composer verdict : %s\n' "$(fm_backend_composer_state herdr "$TARGET" codex)"
} > "$OUT/probe-herdr-$MODE.txt"

fm_backend_herdr_capture_ansi "$TARGET" 24 > "$OUT/pane-before-herdr-$MODE.ansi" 2>/dev/null || true

TASK="snowherdr-$MODE"
cat > "$LAB/home/state/$TASK.meta" <<EOF
window=$TARGET
backend=herdr
kind=ship
harness=codex
EOF

set +e
FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$LAB/home" \
  "$ROOT/bin/fm-send.sh" "$TASK" \
  "Scope cut: the artifact is about a dozen views, not eighty-seven. Stop and re-read the brief." \
  > "$OUT/fm-send-stdout-herdr-$MODE.txt" 2> "$OUT/fm-send-stderr-herdr-$MODE.txt"
SEND_RC=$?
set -e
sleep 1
cp "$TYPED_LOG" "$OUT/pane-stdin-herdr-$MODE.txt"

{
  printf 'fm-send exit      : %s\n' "$SEND_RC"
  printf 'durable record    : %s\n' "$(ls "$LAB/home/state/$TASK.inbox"/*.msg 2>/dev/null | head -1 | sed "s#$LAB#<lab>#")"
  printf 'skip notice       : %s\n' \
    "$(grep -c 'doorbell skipped (composer visibly holds pending text)' "$OUT/fm-send-stderr-herdr-$MODE.txt")"
  printf 'bytes typed into pane: %s\n' "$(wc -c < "$OUT/pane-stdin-herdr-$MODE.txt" | tr -d ' ')"
} >> "$OUT/probe-herdr-$MODE.txt"

cat "$OUT/probe-herdr-$MODE.txt"
printf -- '--- bytes the pane received on stdin ---\n'
cat "$OUT/pane-stdin-herdr-$MODE.txt"
