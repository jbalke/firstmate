#!/usr/bin/env bash
# Live product driver for the Codex-snow doorbell fix.
#
# Stands bin/fm-send.sh up the way an operator runs it (isolated FM_HOME, real
# durable inbox, real tmux backend, private tmux server) against a pane whose
# screen is the real Codex snow capture from
# tests/fixtures/codex-snow-composer.ansi-escaped, rendered by a process the
# liveness probe classifies as a live codex agent, with the terminal cursor
# parked in the composer exactly as Codex parks it.
#
# Usage: snow-doorbell-live.sh <clean|typed|wrapped> <outdir>
#   clean    - snow only on the prompt row and its padding (the reported bug)
#   typed    - operator words typed among the snow (must still be protected)
#   wrapped  - snow on the prompt row, real words on the wrapped row below
set -u

ROOT=${ROOT:?}
MODE=$1
unset NO_MISTAKES_GATE
# The repo's sanctioned test-harness escape hatch (bin/fm-gate-refuse-lib.sh),
# exported by tests/lib.sh for every test that drives the real fm-send.
export FM_GATE_REFUSE_BYPASS=1
OUT=$2
mkdir -p "$OUT"

SOCKET="fm-snow-live-$$-$MODE"
SESSION="snowlive"
WIN="hx-codex"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-snow-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TYPED_LOG="$LAB/pane-stdin.log"
: > "$TYPED_LOG"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

REAL_TMUX=$(command -v tmux)
mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/home/state"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# The exact screen this pane renders, built from the real capture. `typed`
# inserts operator words right after the prompt glyph; `wrapped` adds a real
# wrapped continuation row under the snow-covered prompt row.
FIXTURE="$ROOT/tests/fixtures/codex-snow-composer.ansi-escaped"
python3 - "$FIXTURE" "$MODE" > "$LAB/screen.ansi" <<'PYS'
import sys
raw = open(sys.argv[1]).read().rstrip("\n")
screen = raw.encode().decode("unicode_escape").encode("latin-1").decode("utf-8")
mode = sys.argv[2]
rows = screen.split("\r\n")
if mode == "typed":
    rows[3] = rows[3].replace("\u203a", "\u203aship the scope cut ", 1)
elif mode in ("wrapped", "wrapped-cursor"):
    rows.insert(4, "relaunch worker four")
sys.stdout.write("\r\n".join(rows))
PYS

# The pane process: named `codex` so the real tmux liveness probe classifies it
# alive, renders the real capture, parks the cursor on the prompt row, and
# records every byte the doorbell types into it.
cat > "$LAB/bin/codex" <<SH
#!/usr/bin/env bash
set -u
render() {
  printf '\033[2J\033[H'
  cat "$LAB/screen.ansi"
  # Codex keeps the terminal cursor in its composer; row 4 col 2 is just after
  # the prompt glyph in this capture. wrapped-cursor parks it at the end of the
  # typed wrapped row instead, where a real composer leaves it.
  case "$MODE" in
    wrapped-cursor) printf '\033[5;21H' ;;
    *) printf '\033[4;2H' ;;
  esac
}
render
# One submitted line per Enter, then the composer clears - what Codex does.
while IFS= read -r line; do
  printf '%s\n' "\$line" >> "$TYPED_LOG"
  render
done
SH
chmod +x "$LAB/bin/codex"

ROWS=$(awk 'END{print NR}' RS='\r\n' "$LAB/screen.ansi")
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y "$ROWS"
# argv[0] is the codex path so the real tmux liveness probe
# (fm_backend_tmux_agent_state) reads this foreground process as a live codex
# agent, exactly as it reads a real one.
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$WIN" -c "$ROOT" \
  -- bash -c "exec -a '$LAB/bin/codex' bash '$LAB/bin/codex'"
sleep 1.5

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

{
  printf 'mode=%s\n' "$MODE"
  printf 'pane agent state : %s\n' "$(fm_backend_agent_state tmux "$SESSION:$WIN")"
  printf 'cursor row       : %s\n' "$(fm_tmux_composer_cursor_row "$SESSION:$WIN")"
  printf 'composer verdict : %s\n' "$(fm_backend_composer_state tmux "$SESSION:$WIN" codex)"
} > "$OUT/probe-$MODE.txt"

tmux -L "$SOCKET" capture-pane -p -e -t "$SESSION:$WIN" > "$OUT/pane-before-$MODE.ansi"

TASK="snow-$MODE"
printf 'window=%s:%s\nkind=ship\nharness=codex\n' "$SESSION" "$WIN" > "$LAB/home/state/$TASK.meta"

set +e
FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$LAB/home" \
  "$ROOT/bin/fm-send.sh" "$TASK" \
  "Scope cut: the artifact is about a dozen views, not eighty-seven. Stop and re-read the brief." \
  > "$OUT/fm-send-stdout-$MODE.txt" 2> "$OUT/fm-send-stderr-$MODE.txt"
SEND_RC=$?
set -e

# The watcher's own re-ring ladder, driven against the same live pane through
# the shared owner bin/fm-task-inbox-lib.sh that bin/fm-watch.sh calls. With no
# grace, three attempts either deliver the doorbell or spend the budget and
# escalate a stale wake.
if [ "$MODE" = ladder ]; then
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-task-inbox-lib.sh"
  export FM_TASK_INBOX_GRACE_SECS=0
  for attempt in 1 2 3 4; do
    action=$(fm_task_inbox_due_action "$LAB/home/state" "$TASK")
    printf 'ladder attempt %s: due_action=%s' "$attempt" "${action%% *}" >> "$OUT/probe-$MODE.txt"
    case "$action" in
      ring\ *)
        ring_rc=0
        fm_task_inbox_ring tmux "$SESSION:$WIN" "${action#ring }" codex || ring_rc=$?
        fm_task_inbox_record_ring "$LAB/home/state" "$TASK" "${action#ring }" || true
        printf ' ring_rc=%s doorbell-lines-in-pane=%s\n' "$ring_rc" \
          "$(grep -c 'Firstmate instruction waiting' "$TYPED_LOG")" >> "$OUT/probe-$MODE.txt"
        ;;
      *) printf '\n' >> "$OUT/probe-$MODE.txt" ;;
    esac
    sleep 0.5
  done
fi

sleep 1
tmux -L "$SOCKET" capture-pane -p -e -t "$SESSION:$WIN" > "$OUT/pane-after-$MODE.ansi"
cp "$TYPED_LOG" "$OUT/pane-stdin-$MODE.txt"

{
  printf 'fm-send exit      : %s\n' "$SEND_RC"
  printf 'durable record    : %s\n' "$(ls "$LAB/home/state/$TASK.inbox"/*.msg 2>/dev/null | head -1 | sed "s#$LAB#<lab>#")"
  printf 'skip notice       : %s\n' \
    "$(grep -c 'doorbell skipped (composer visibly holds pending text)' "$OUT/fm-send-stderr-$MODE.txt")"
  printf 'bytes typed into pane: %s\n' "$(wc -c < "$OUT/pane-stdin-$MODE.txt" | tr -d ' ')"
} >> "$OUT/probe-$MODE.txt"

cat "$OUT/probe-$MODE.txt"
printf -- '--- fm-send stderr ---\n'
cat "$OUT/fm-send-stderr-$MODE.txt"
printf -- '--- bytes the pane received on stdin ---\n'
cat "$OUT/pane-stdin-$MODE.txt"
