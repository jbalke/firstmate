#!/usr/bin/env bash
# Behavioral validation for the public harness-adapter router.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLAN="$ROOT/bin/fm-harness-adapter-plan.sh"

replacement=$($PLAN recovery replacement-secondmate codex) \
  || fail "router rejected the replacement-secondmate codex plan"
jq -e '
  .operation == "recovery" and
  .scenario == "replacement-secondmate" and
  .common == [
    "references/common/control-and-recovery.md",
    "references/common/dispatch.md",
    "references/common/model-and-effort.md",
    "references/common/primary-hooks.md"
  ] and
  .harness == "references/harness/codex.md"
' <<<"$replacement" >/dev/null || fail "router returned a non-normalized replacement plan"

alias_plan=$($PLAN interrupt default pi-signed) \
  || fail "router rejected the pi-signed alias"
jq -e '
  .common == ["references/common/control-and-recovery.md"] and
  .harness == "references/harness/pi.md"
' <<<"$alias_plan" >/dev/null || fail "router did not normalize the pi-signed harness reference"

jq -r '.resolved.common[], .resolved.harness' <<<"$replacement" | while IFS= read -r path; do
  [ -r "$path" ] || fail "router returned an unreadable resolved resource: $path"
done

if $PLAN recovery missing codex >/dev/null 2>&1; then
  fail "router accepted an unknown recovery scenario"
fi
pass "harness adapter router normalizes plans and resolves selected resources"
