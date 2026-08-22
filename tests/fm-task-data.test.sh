#!/usr/bin/env bash
# Behavior tests for the project-grouped task data layout (bin/fm-task-data-lib.sh)
# and the list/archive/prune tool built on it (bin/fm-task-data.sh).
#
# The layout change is a read-path compatibility problem: an existing home has
# hundreds of folders at the legacy data/<task-id>/ location and they must keep
# resolving, while every new write lands under data/tasks/<project>/<task-id>/.
# These tests drive that through the executable interfaces only.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-data)

# A fresh home with both layouts populated: two project-grouped folders written
# by the real scaffold, and one legacy folder placed by hand the way an existing
# home already holds them.
new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  rm -rf "$home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

scaffold_ship() {  # <home> <task-id> <project> [title]
  FM_HOME="$1" FM_DATA_OVERRIDE="$1/data" FM_STATE_OVERRIDE="$1/state" \
    "$ROOT/bin/fm-brief.sh" "$2" "$3" --mode direct-PR --title "${4:-$2}"
}

run_tool() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-task-data.sh" "$@"
}

# --- Part 1: layout and backward compatibility ------------------------------

test_scaffold_writes_project_grouped_path() {
  local home out
  home=$(new_home scaffold)
  out=$(scaffold_ship "$home" alpha-task front-client "Fix the grid" 2>&1) \
    || fail "scaffold failed: $out"
  assert_present "$home/data/tasks/front-client/alpha-task/brief.md" \
    "a fresh scaffold must write under data/tasks/<project>/<task-id>/"
  assert_absent "$home/data/alpha-task/brief.md" \
    "a fresh scaffold must not write the legacy path"
  pass "fm-brief.sh: a fresh scaffold writes the project-grouped path"
}

test_marker_records_project_title_and_date() {
  local home marker
  home=$(new_home marker)
  scaffold_ship "$home" beta-task vega-ui "Port the dialog" >/dev/null 2>&1 \
    || fail "scaffold failed"
  marker="$home/data/tasks/vega-ui/beta-task/task.meta"
  assert_present "$marker" "the scaffold must write the grouping marker"
  assert_grep 'project=vega-ui' "$marker" "marker must record the project"
  assert_grep 'title=Port the dialog' "$marker" "marker must record the title"
  assert_grep "created=$(date -u +%Y-%m-%d)" "$marker" \
    "marker must record the creation date"
  pass "fm-brief.sh: the marker records project, title, and creation date"
}

test_title_never_enters_the_path() {
  local home
  home=$(new_home titlepath)
  scaffold_ship "$home" gamma-task front-client "A Title With Spaces" >/dev/null 2>&1 \
    || fail "scaffold failed"
  assert_present "$home/data/tasks/front-client/gamma-task/brief.md" \
    "the path must be the task id alone, never the title"
  pass "fm-brief.sh: a reworded title cannot move the folder"
}

test_project_less_task_uses_the_documented_literal() {
  local home
  home=$(new_home noproject)
  FM_SECONDMATE_CHARTER='A charter.' \
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-brief.sh" delta-mate --secondmate --no-projects >/dev/null 2>&1 \
    || fail "secondmate scaffold failed"
  assert_present "$home/data/tasks/_none/delta-mate/brief.md" \
    "a task with no project must use the _none literal"
  pass "fm-brief.sh: a project-less task uses the documented _none literal"
}

# Every read-path caller must find a task whose data exists only at the legacy
# location, and none of them may create a second copy at the new path.
test_legacy_folder_is_found_by_every_reader() {
  local home out rc
  home=$(new_home legacy)
  mkdir -p "$home/data/legacy-task"
  printf 'legacy brief\n' > "$home/data/legacy-task/brief.md"
  printf 'legacy report\n' > "$home/data/legacy-task/report.md"

  # fm-spawn.sh resolves the brief before it validates anything else, so an
  # unresolvable brief is the distinguishable failure this asserts against.
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-spawn.sh" legacy-task nonexistent-project --mode direct-PR 2>&1); rc=$?
  [ "$rc" -eq 0 ] && fail "fm-spawn.sh unexpectedly succeeded"
  assert_not_contains "$out" "no brief at" \
    "fm-spawn.sh must resolve a legacy task data directory"

  # fm-control.sh relaunch reaches the same brief resolution.
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-control.sh" legacy-task relaunch 2>&1 || true)
  assert_not_contains "$out" "has no instructions at" \
    "fm-control.sh must resolve a legacy task data directory"

  # fm-captain-hold.sh treats a present report as proof the origin exists here.
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" verify legacy-task 2>&1 || true)
  assert_not_contains "$out" "unknown origin" \
    "fm-captain-hold.sh must resolve a legacy task data directory"

  # fm-teardown.sh refuses a scout with no report; the legacy report satisfies it.
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" legacy-task 2>&1 || true)
  assert_not_contains "$out" "has no report at" \
    "fm-teardown.sh must resolve a legacy task data directory"

  # The listing tool is the fifth reader and must see the folder as one task.
  out=$(run_tool "$home" list)
  assert_contains "$out" "legacy-task" "the tool must list a legacy folder"

  assert_absent "$home/data/tasks/legacy-task" \
    "no reader may duplicate a legacy task into the new layout"
  [ ! -d "$home/data/tasks" ] || [ -z "$(find "$home/data/tasks" -name legacy-task -print -quit)" ] \
    || fail "a legacy task was duplicated under data/tasks/"
  pass "layout: a legacy-only task is found by every reader and never duplicated"
}

test_write_reuses_an_existing_legacy_directory() {
  local home out
  home=$(new_home legacywrite)
  mkdir -p "$home/data/split-task"
  printf 'evidence\n' > "$home/data/split-task/screenshot-note.md"
  out=$(scaffold_ship "$home" split-task front-client 2>&1) || fail "scaffold failed: $out"
  assert_present "$home/data/split-task/brief.md" \
    "a task with legacy data must keep writing there"
  assert_present "$home/data/split-task/task.meta" \
    "the marker must join the existing folder, not a second one"
  assert_absent "$home/data/tasks/front-client/split-task" \
    "one task's record must never be split across two locations"
  pass "layout: a task with legacy data keeps using it rather than splitting"
}

test_top_level_data_files_are_untouched() {
  local home out
  home=$(new_home toplevel)
  printf '## In flight\n' > "$home/data/backlog.md"
  printf 'captain\n' > "$home/data/captain.md"
  mkdir -p "$home/data/handoff"
  scaffold_ship "$home" epsilon-task vega-ui >/dev/null 2>&1 || fail "scaffold failed"
  out=$(run_tool "$home" list)
  assert_not_contains "$out" "backlog.md" "top-level data files are not task folders"
  assert_not_contains "$out" "handoff" "data/handoff/ is not a task folder"
  assert_present "$home/data/backlog.md" "backlog.md must be untouched"
  pass "layout: data/ keeps its own top-level files and directories"
}

# --- Part 3: the prune tool -------------------------------------------------

# One fixture home with folders in both layouts, an in-flight task, a protected
# folder, and images alongside words.
build_fixture() {  # <name>
  local home
  home=$(new_home "$1")
  scaffold_ship "$home" ship-a front-client >/dev/null 2>&1 || fail "scaffold ship-a failed"
  scaffold_ship "$home" ship-b vega-ui >/dev/null 2>&1 || fail "scaffold ship-b failed"
  scaffold_ship "$home" ship-live front-client >/dev/null 2>&1 || fail "scaffold ship-live failed"
  mkdir -p "$home/data/old-legacy"
  printf 'legacy report\n' > "$home/data/old-legacy/report.md"
  printf 'PNGDATA\n' > "$home/data/old-legacy/shot.PNG"

  printf 'report words\n' > "$home/data/tasks/front-client/ship-a/report.md"
  printf 'PNGDATA\n' > "$home/data/tasks/front-client/ship-a/before.png"
  printf 'JPGDATA\n' > "$home/data/tasks/front-client/ship-a/after.jpeg"
  printf 'report words\n' > "$home/data/tasks/vega-ui/ship-b/report.md"

  # ship-live is still working: teardown removes this record, so its presence is
  # what marks a task as unfinished.
  printf 'kind=ship\n' > "$home/state/ship-live.meta"
  printf '%s\n' "$home"
}

test_dry_run_removes_nothing() {
  local home out
  home=$(build_fixture dryrun)
  out=$(run_tool "$home" prune)
  assert_contains "$out" "DRY RUN" "prune must default to a dry run"
  assert_contains "$out" "nothing was changed" "the dry run must say it changed nothing"
  assert_present "$home/data/tasks/front-client/ship-a/report.md" "dry run must keep new-layout data"
  assert_present "$home/data/tasks/front-client/ship-a/before.png" "dry run must keep images"
  assert_present "$home/data/old-legacy/report.md" "dry run must keep legacy-layout data"
  assert_contains "$out" "ship-a" "the dry run must print what it would remove"
  assert_contains "$out" "old-legacy" "the dry run must cover both layouts"
  pass "fm-task-data.sh: the dry run is the default and removes nothing"
}

test_in_flight_task_is_refused() {
  local home out
  home=$(build_fixture inflight)
  out=$(run_tool "$home" prune --yes)
  assert_contains "$out" "in flight" "an unfinished task must be named as skipped"
  assert_present "$home/data/tasks/front-client/ship-live/brief.md" \
    "an unfinished task's folder must survive"
  pass "fm-task-data.sh: a task that is not finished is refused and named"
}

test_protected_folder_needs_the_override() {
  local home out
  home=$(build_fixture protected)
  out=$(run_tool "$home" protect ship-a)
  assert_contains "$out" "protected:" "protect must report what it marked"

  out=$(run_tool "$home" prune --project front-client --yes)
  assert_contains "$out" "protected:" "a protected skip must be stated plainly"
  assert_present "$home/data/tasks/front-client/ship-a/report.md" \
    "a protected folder must survive without the override"

  out=$(run_tool "$home" prune --project front-client --include-protected --yes)
  assert_absent "$home/data/tasks/front-client/ship-a" \
    "--include-protected must remove a protected folder"
  pass "fm-task-data.sh: a protected folder is skipped without the override and removed with it"
}

test_images_only_leaves_every_md_intact() {
  local home out
  home=$(build_fixture imagesonly)
  out=$(run_tool "$home" prune --images-only --yes)
  assert_contains "$out" "images only" "the plan must say images only"
  assert_absent "$home/data/tasks/front-client/ship-a/before.png" "png must go"
  assert_absent "$home/data/tasks/front-client/ship-a/after.jpeg" "jpeg must go"
  assert_absent "$home/data/old-legacy/shot.PNG" "an uppercase extension must go"
  assert_present "$home/data/tasks/front-client/ship-a/report.md" "report.md must stay"
  assert_present "$home/data/tasks/front-client/ship-a/brief.md" "brief.md must stay"
  assert_present "$home/data/tasks/vega-ui/ship-b/report.md" "every other report must stay"
  assert_present "$home/data/old-legacy/report.md" "a legacy report must stay"
  assert_present "$home/data/tasks/front-client/ship-a/task.meta" "the marker must stay"
  [ -z "$(find "$home/data" -name '*.md' -newer "$home/data" -size 0 -print -quit)" ] \
    || fail "an .md file was emptied"
  pass "fm-task-data.sh: images-only leaves every .md intact"
}

test_filters_compose() {
  local home out
  home=$(build_fixture filters)
  out=$(run_tool "$home" prune --project vega-ui)
  assert_contains "$out" "ship-b" "the project filter must select its own project"
  assert_not_contains "$out" "ship-a" "the project filter must exclude other projects"

  out=$(run_tool "$home" prune --task ship-a)
  assert_contains "$out" "ship-a" "the task filter must select its task"
  assert_not_contains "$out" "ship-b" "the task filter must exclude other tasks"

  # Nothing in the fixture is older than a day, so age composes to an empty set.
  out=$(run_tool "$home" prune --project vega-ui --older-than 1)
  assert_contains "$out" "nothing selected" "composed filters must intersect"
  pass "fm-task-data.sh: project, task, and age filters compose"
}

test_archive_moves_instead_of_deleting() {
  local home out archive
  home=$(build_fixture archive)
  archive="$TMP_ROOT/archive-store"
  rm -rf "$archive"
  out=$(run_tool "$home" prune --task ship-b --archive "$archive" --yes)
  assert_contains "$out" "archived:" "archiving must report what it moved"
  assert_absent "$home/data/tasks/vega-ui/ship-b/report.md" "the source file must move"
  assert_present "$archive/vega-ui/ship-b/report.md" "the archive must hold the file"
  pass "fm-task-data.sh: --archive moves instead of deleting"
}

test_second_run_is_safe() {
  local home first second
  home=$(build_fixture idempotent)
  first=$(run_tool "$home" prune --task ship-a --yes 2>&1) || fail "first run failed: $first"
  second=$(run_tool "$home" prune --task ship-a --yes 2>&1) || fail "second run failed: $second"
  assert_contains "$second" "nothing selected" "a repeated prune must be a no-op"
  pass "fm-task-data.sh: running twice is safe"
}

test_scripts_parse() {
  local out rc
  for script in bin/fm-task-data-lib.sh bin/fm-task-data.sh; do
    out=$(bash -n "$ROOT/$script" 2>&1); rc=$?
    expect_code 0 "$rc" "bash -n $script must parse cleanly (got: $out)"
  done
  pass "fm-task-data: both scripts parse cleanly"
}

test_scripts_parse
test_scaffold_writes_project_grouped_path
test_marker_records_project_title_and_date
test_title_never_enters_the_path
test_project_less_task_uses_the_documented_literal
test_legacy_folder_is_found_by_every_reader
test_write_reuses_an_existing_legacy_directory
test_top_level_data_files_are_untouched
test_dry_run_removes_nothing
test_in_flight_task_is_refused
test_protected_folder_needs_the_override
test_images_only_leaves_every_md_intact
test_filters_compose
test_archive_moves_instead_of_deleting
test_second_run_is_safe
