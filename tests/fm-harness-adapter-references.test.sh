#!/usr/bin/env bash
# Behavioral validation for the public harness-adapter router.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLAN="$ROOT/bin/fm-harness-adapter-plan.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-adapter-references)

check_plan() {
  local operation=$1 scenario=$2 harness=$3 common=$4 harness_path=$5 output
  output=$($PLAN "$operation" "$scenario" "$harness") \
    || fail "router rejected $operation.$scenario for $harness"
  jq -e \
    --arg operation "$operation" \
    --arg scenario "$scenario" \
    --arg harness_path "$harness_path" \
    --argjson common "$common" '
      .operation == $operation and
      .scenario == $scenario and
      .common == $common and
      .harness == $harness_path and
      (.resolved.common | length) == ($common | length) and
      (.resolved.harness | type) == "string"
    ' <<<"$output" >/dev/null || fail "router returned a non-normalized $operation.$scenario plan for $harness"
}

dispatch='["references/common/dispatch.md","references/common/model-and-effort.md"]'
control='["references/common/control-and-recovery.md"]'
primary='["references/common/primary-hooks.md"]'
model='["references/common/model-and-effort.md"]'
replacement='["references/common/control-and-recovery.md","references/common/dispatch.md","references/common/model-and-effort.md"]'
secondmate='["references/common/control-and-recovery.md","references/common/primary-hooks.md"]'
replacement_secondmate='["references/common/control-and-recovery.md","references/common/dispatch.md","references/common/model-and-effort.md","references/common/primary-hooks.md"]'
configured_profile='["references/common/model-and-effort.md","references/common/dispatch.md"]'
verify='["references/common/dispatch.md","references/common/control-and-recovery.md","references/common/primary-hooks.md","references/common/model-and-effort.md"]'

check_plan start default claude "$dispatch" references/harness/claude.md
check_plan start trust-dialog codex "$control" references/harness/codex.md
check_plan trust default opencode "$control" references/harness/opencode.md
check_plan skill default pi "$control" references/harness/pi.md
check_plan interrupt default pi-signed "$control" references/harness/pi.md
check_plan exit default grok "$control" references/harness/grok.md
check_plan resume default kimi "$control" references/harness/kimi.md
check_plan recovery default cursor "$control" references/harness/cursor.md
check_plan recovery replacement-profile muse "$replacement" references/harness/muse.md
check_plan recovery secondmate claude "$secondmate" references/harness/claude.md
check_plan recovery replacement-secondmate codex "$replacement_secondmate" references/harness/codex.md
check_plan primary default opencode "$primary" references/harness/opencode.md
check_plan model-effort default pi "$model" references/harness/pi.md
check_plan model-effort configured-profile pi-signed "$configured_profile" references/harness/pi.md
check_plan verify default grok "$verify" references/harness/grok.md

if $PLAN recovery missing codex >/dev/null 2>&1; then
  fail "router accepted an unknown recovery scenario"
fi

cp -R "$ROOT/.agents/skills/harness-adapters" "$TMP_ROOT/harness-adapters"
rm "$TMP_ROOT/harness-adapters/references/harness/muse.md"
if FM_HARNESS_ADAPTER_SKILL_DIR="$TMP_ROOT/harness-adapters" \
  $PLAN recovery replacement-profile muse >/dev/null 2>&1; then
  fail "router accepted a plan with a missing selected resource"
fi

pass "harness adapter router validates every declared route and selected resource"
