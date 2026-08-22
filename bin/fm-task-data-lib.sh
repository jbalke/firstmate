#!/usr/bin/env bash
# fm-task-data-lib.sh - single owner of a task's durable data directory path.
#
# Current layout, project-grouped so a whole project's records can be listed,
# archived, or pruned without parsing prose out of every brief:
#
#   <data>/tasks/<project>/<task-id>/
#
# <project> is the project's registry name as it appears in data/projects.md
# (front-client, vega-ui, ...), never a path. A task with no project - a
# firstmate-repo task or a secondmate charter - uses the literal
# FM_TASK_DATA_NO_PROJECT ("_none"). Registry names cannot begin with an
# underscore, so that literal can never collide with a real project.
#
# Legacy layout, still fully readable and never migrated by these helpers:
#
#   <data>/<task-id>/
#
# Read resolution is new-first, then legacy. Writes use the new layout EXCEPT
# for a task that already has a legacy directory: that task keeps using it, so
# one task's record is never split across two locations.
#
# The marker file FM_TASK_DATA_MARKER ("task.meta") records the project, title,
# kind, and creation date at scaffold time, in the same `key=value` shape as
# state/<id>.meta, so grouping never depends on parsing brief.md prose. A folder
# containing FM_TASK_DATA_PROTECTED (".protected") is never removed by
# bin/fm-task-data.sh without its explicit override.
#
# No side effects on source. set -u / set -e safe.

FM_TASK_DATA_SUBDIR=tasks
FM_TASK_DATA_NO_PROJECT=_none
FM_TASK_DATA_MARKER=task.meta
# shellcheck disable=SC2034 # Read by bin/fm-task-data.sh, not by this library.
FM_TASK_DATA_PROTECTED=.protected

# Validate a task id used as one path component. Refuses anything that could
# escape the data root or shadow the tasks/ container itself.
fm_task_data_valid_id() {  # <task-id>
  local id=$1
  case "$id" in
    ''|.|..|"$FM_TASK_DATA_SUBDIR") return 1 ;;
    */*|*$'\n'*) return 1 ;;
    -*) return 1 ;;
  esac
  return 0
}

# Normalize a project name into its path component. An empty project resolves to
# the documented no-project literal. Anything that is not a single safe path
# component is refused rather than silently rewritten, so a malformed registry
# name cannot quietly scatter task data.
fm_task_data_project_slug() {  # <project>
  local project=${1:-}
  if [ -z "$project" ]; then
    printf '%s\n' "$FM_TASK_DATA_NO_PROJECT"
    return 0
  fi
  case "$project" in
    .|..) ;;
    */*|*$'\n'*|-*) ;;
    *) printf '%s\n' "$project"; return 0 ;;
  esac
  echo "error: '$project' is not a usable project name for a task data directory" >&2
  return 1
}

# Print the existing durable data directory for a task, or fail with no output.
# New layout wins over legacy so a migrated task is never read from both.
fm_task_data_find() {  # <data-root> <task-id>
  local data=$1 id=$2 candidate
  fm_task_data_valid_id "$id" || return 1
  for candidate in "$data/$FM_TASK_DATA_SUBDIR"/*/"$id"; do
    [ -d "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  if [ -d "$data/$id" ]; then
    printf '%s\n' "$data/$id"
    return 0
  fi
  return 1
}

# Print the durable data directory a caller should use for a task: the existing
# one when the task already has records anywhere, otherwise the new-layout path
# under the given project. Creates nothing.
fm_task_data_dir() {  # <data-root> <task-id> [project]
  local data=$1 id=$2 project=${3:-} slug found
  fm_task_data_valid_id "$id" || {
    echo "error: '$id' is not a usable task id for a data directory" >&2
    return 1
  }
  if found=$(fm_task_data_find "$data" "$id"); then
    printf '%s\n' "$found"
    return 0
  fi
  slug=$(fm_task_data_project_slug "$project") || return 1
  printf '%s\n' "$data/$FM_TASK_DATA_SUBDIR/$slug/$id"
}

# fm_task_data_dir, then create the directory.
fm_task_data_ensure_dir() {  # <data-root> <task-id> [project]
  local dir
  dir=$(fm_task_data_dir "$@") || return 1
  mkdir -p "$dir" || return 1
  printf '%s\n' "$dir"
}

# Write the grouping marker. Idempotent: rewritten in place on every scaffold so
# a re-scaffold cannot leave a stale project or title behind.
fm_task_data_write_marker() {  # <dir> <project> <title> <kind>
  local dir=$1 project=${2:-} title=${3:-} kind=${4:-} slug tmp
  slug=$(fm_task_data_project_slug "$project") || return 1
  # Newlines would break the one-key-per-line shape the reader relies on.
  title=$(printf '%s' "$title" | tr '\n\r' '  ')
  tmp="$dir/$FM_TASK_DATA_MARKER.tmp.$$"
  {
    printf 'project=%s\n' "$slug"
    printf 'title=%s\n' "$title"
    printf 'kind=%s\n' "$kind"
    printf 'created=%s\n' "$(date -u +%Y-%m-%d)"
  } > "$tmp" || return 1
  mv -f -- "$tmp" "$dir/$FM_TASK_DATA_MARKER"
}

# Read one marker key, printing nothing when the marker or key is absent.
fm_task_data_marker_value() {  # <dir> <key>
  local marker="$1/$FM_TASK_DATA_MARKER" key=$2
  [ -f "$marker" ] || return 0
  awk -v k="$key" '
    index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }
  ' "$marker"
}

# The project a directory belongs to: its marker first, then its position in the
# new layout, and the no-project literal for a legacy folder that records
# neither. A folder whose marker is unreadable is still identifiable this way.
fm_task_data_project_of_dir() {  # <data-root> <dir>
  local data=$1 dir=$2 project parent
  project=$(fm_task_data_marker_value "$dir" project)
  if [ -n "$project" ]; then
    printf '%s\n' "$project"
    return 0
  fi
  parent=$(dirname -- "$dir")
  if [ "$(dirname -- "$parent")" = "$data/$FM_TASK_DATA_SUBDIR" ]; then
    printf '%s\n' "$(basename -- "$parent")"
    return 0
  fi
  printf '%s\n' "$FM_TASK_DATA_NO_PROJECT"
}
