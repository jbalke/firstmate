#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR=${FM_HARNESS_ADAPTER_SKILL_DIR:-"$ROOT/.agents/skills/harness-adapters"}
ROUTER="$SKILL_DIR/SKILL.md"

usage() {
  printf 'usage: %s <operation> <scenario> <harness>\n' "${0##*/}" >&2
  exit 64
}

[ "$#" -eq 3 ] || usage
operation=$1
scenario=$2
harness=$3

routing_json=$(
  awk '
    /^```json harness-adapter-routing-v1$/ { capture = 1; next }
    capture && /^```$/ { exit }
    capture { print }
  ' "$ROUTER"
) || exit 1

plan=$(
  jq -ce --arg operation "$operation" --arg scenario "$scenario" --arg harness "$harness" '
    (.operations[$operation][$scenario] // error("unknown operation scenario")) as $common |
    (.harnesses[$harness] // error("unknown harness")) as $harness_path |
    {
      operation: $operation,
      scenario: $scenario,
      common: $common,
      harness: $harness_path
    }
  ' <<<"$routing_json"
) || exit 65

resolved_paths=$(jq -r '.common[], .harness' <<<"$plan") || exit 65
while IFS= read -r path; do
  case "/$path/" in
    /*/../*|/*/./*)
      printf 'invalid harness adapter reference: %s\n' "$path" >&2
      exit 66
      ;;
  esac
  case "$path" in
    /*|'')
      printf 'invalid harness adapter reference: %s\n' "$path" >&2
      exit 66
      ;;
  esac
  [ -f "$SKILL_DIR/$path" ] && [ -r "$SKILL_DIR/$path" ] || {
    printf 'unreadable harness adapter reference: %s\n' "$path" >&2
    exit 66
  }
done <<<"$resolved_paths"

jq -ce --arg skill_dir "$SKILL_DIR" '
  . + {
    resolved: {
      common: [.common[] | $skill_dir + "/" + .],
      harness: ($skill_dir + "/" + .harness)
    }
  }
' <<<"$plan"
