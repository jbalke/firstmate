#!/usr/bin/env bash
# Hand-driven transcript of the fork's post-merge contribution changes.
# Stands up a real firstmate home and runs the real CLIs against it.
set -u
ROOT=$1
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-drive.XXXXXX")
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

say() { printf '\n\033[1m$ %s\033[0m\n' "$*"; }
run() { say "$*"; "$@"; printf '(exit %s)\n' "$?"; }

mkdir -p "$HOME_DIR"/{data,state,config,projects,fakebin,forge,root/bin,wt}
printf '#!/bin/sh\nexit 1\n' > "$HOME_DIR/fakebin/tmux"
printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/fakebin/no-mistakes"
printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/root/bin/fm-guard.sh"
chmod +x "$HOME_DIR/fakebin/"* "$HOME_DIR/root/bin/fm-guard.sh"
printf 'worktree=%s/wt\nkind=ship\n' "$HOME_DIR" > "$HOME_DIR/state/delivery.meta"
chmod 600 "$HOME_DIR/state/delivery.meta"
printf '%s\n' "$HEAD_A" > "$HOME_DIR/forge/head"
for f in comments reviews inline labels events; do printf '[]\n' > "$HOME_DIR/forge/$f.json"; done
cp "$(dirname "$0")/gh-fixture.sh" "$HOME_DIR/fakebin/gh"; chmod +x "$HOME_DIR/fakebin/gh"

# The captain's backlog, exactly as an operator would leave it: one good row,
# and three rows whose owner id the durable layer cannot name.
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## Queued
- [ ] delivery - Contribution delivery https://github.com/o/r/pull/8 (repo: sample) (kind: ship)
- [ ] tasks - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)
- [ ] -dash - Filed https://github.com/o/r/issues/9 (repo: sample) (kind: ship)
- [ ] upstream - Filed https://github.com/o/r/pull/8 (repo: kunchenguid/firstmate) (kind: ship)
MD

mkdir -p "$HOME_DIR/data/delivery"
jq -n --arg head "$HEAD_A" --arg at 2026-09-15T08:00:00Z '
  {schema:"fm-contributions.v1",task:"delivery",records:[{
    url:"https://github.com/o/r/pull/8",kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
    observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",review_decision:"APPROVED",
      can_merge:false,checks:[],reviews:[],events:[]}}]}' > "$HOME_DIR/data/delivery/contributions.json"

with_home() {
  PATH="$HOME_DIR/fakebin:$PATH" FORGE="$HOME_DIR/forge" \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR/root" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="${FM_DATA:-$HOME_DIR/data}" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}

echo "================ backlog the captain left ================"
cat "$HOME_DIR/data/backlog.md"

echo
echo "================ 1. poll the forge ================"
say "fm-contributions.sh poll"
with_home "$ROOT/bin/fm-contributions.sh" poll; printf '(exit %s)\n' "$?"

echo
echo "================ 2. which forge reads were actually spent ================"
say "cat forge/calls.log"
cat "$HOME_DIR/forge/calls.log"
printf '\nreads against issues/9 (owned only by the unnameable "-dash"): %s\n' \
  "$(grep -c 'issues/9' "$HOME_DIR/forge/calls.log")"

echo
echo "================ 3. durable records written ================"
say "find data -name contributions.json"
( cd "$HOME_DIR" && find data -name contributions.json | sort )
say "jq .records[0].checked_at data/delivery/contributions.json"
jq -r '.records[0].checked_at' "$HOME_DIR/data/delivery/contributions.json"
say "jq .task data/tasks/_no-project/upstream/contributions.json  # prose repo hint fell back to no-project"
jq -r '.task' "$HOME_DIR/data/tasks/_no-project/upstream/contributions.json" 2>/dev/null \
  || ls -R "$HOME_DIR/data/tasks" 2>/dev/null

echo
echo "================ 4. what Bearings reports to the captain ================"
say "fm-bearings-snapshot.sh --json | jq .contributions"
PATH="$HOME_DIR/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BEARINGS_NOW="$NOW" \
  "$ROOT/bin/fm-bearings-snapshot.sh" --json \
  | jq '.contributions | {known,checked,complete,proven_clear,counts}'

echo
echo "================ 5. arm --if-owned on an unnameable-only home ================"
UNOWNED=$(mktemp -d "${TMPDIR:-/tmp}/fm-drive-unowned.XXXXXX")
mkdir -p "$UNOWNED"/{data,state,config,fakebin,root/bin}
printf '#!/bin/sh\nexit 0\n' > "$UNOWNED/root/bin/fm-guard.sh"; chmod +x "$UNOWNED/root/bin/fm-guard.sh"
printf '# Backlog\n\n## Queued\n- [ ] tasks - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' \
  > "$UNOWNED/data/backlog.md"
say "fm-contributions.sh arm --if-owned   # backlog has ONLY the unnameable row"
FM_HOME="$UNOWNED" FM_ROOT_OVERRIDE="$UNOWNED/root" FM_STATE_OVERRIDE="$UNOWNED/state" \
  FM_DATA_OVERRIDE="$UNOWNED/data" FM_CONFIG_OVERRIDE="$UNOWNED/config" \
  FM_CONTRIBUTIONS_NOW="$NOW" "$ROOT/bin/fm-contributions.sh" arm --if-owned
printf '(exit %s)\n' "$?"
say "ls state/*.check.sh"
ls "$UNOWNED/state/"*.check.sh 2>&1 || echo "no check armed - nothing can ever clear it, so nothing was armed"

echo
echo "================ 6. data root spelled with a trailing slash ================"
say 'FM_DATA_OVERRIDE="$HOME/data/" fm-contributions.sh poll'
jq '.records[0].checked_at="2026-09-15T08:00:00Z"' "$HOME_DIR/data/delivery/contributions.json" > "$HOME_DIR/u.json"
mv "$HOME_DIR/u.json" "$HOME_DIR/data/delivery/contributions.json"
FM_DATA="$HOME_DIR/data/" with_home "$ROOT/bin/fm-contributions.sh" poll >/dev/null; printf '(exit %s)\n' "$?"
say "jq .records[0].checked_at data/delivery/contributions.json"
jq -r '.records[0].checked_at' "$HOME_DIR/data/delivery/contributions.json"

say 'same trailing slash, but the data root is now a symlink'
mv "$HOME_DIR/data" "$HOME_DIR/data-target"; ln -s "$HOME_DIR/data-target" "$HOME_DIR/data"
FM_DATA="$HOME_DIR/data/" with_home "$ROOT/bin/fm-contributions.sh" poll 2>&1 | tail -3
printf 'refused as expected: %s\n' "$( FM_DATA="$HOME_DIR/data/" with_home "$ROOT/bin/fm-contributions.sh" poll >/dev/null 2>&1 && echo NO || echo YES )"

rm -rf "$HOME_DIR" "$UNOWNED"
