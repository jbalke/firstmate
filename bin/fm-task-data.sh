#!/usr/bin/env bash
# fm-task-data.sh - list, archive, or prune the durable task data directories
# under a firstmate home's data/ (bin/fm-task-data-lib.sh owns their layout).
#
# Nothing else in firstmate ever deletes these folders, which is deliberate: the
# brief, the report, and the saved evidence are what outlive a task. This is the
# one tool that removes them, so every destructive path prints its plan first and
# does nothing without --yes.
#
# Usage:
#   fm-task-data.sh list [filters]
#   fm-task-data.sh prune [filters] [--images-only] [--archive <dir>] [--yes]
#                         [--include-protected]
#   fm-task-data.sh protect {<task-id>...|<filters>}
#   fm-task-data.sh unprotect {<task-id>...|<filters>}
#
# Filters (repeatable, and they compose - a folder must match every filter kind
# that was given, and any one value within a kind):
#   --project <name>      registry name, or _none for the no-project literal
#   --task <pattern>      task id, or a shell glob over task ids such as
#                         'cvui-*'; quote it so the shell does not expand it
#   --older-than <days>   folder last modified more than <days> days ago
#
# prune options:
#   --images-only         remove only image files (png, jpg, jpeg, gif, webp,
#                         svg, bmp, tiff, avif, heic) and leave the folder and
#                         every other file, so the words survive and the bulk
#                         does not
#   --archive <dir>       move instead of delete, into <dir>/<project>/<task-id>/
#                         preserving the relative path; reversible
#   --yes                 actually do it; without this, prune is a dry run that
#                         prints the plan and changes nothing
#   --include-protected   also act on protected folders (see below)
#
# Always skipped, and named in the output when skipped:
#   - a task still in flight, identified by a live state/<task-id>.meta record;
#     work under way owns its folder
#   - a protected folder, identified by a `.protected` marker file inside it.
#     Use `protect` to add one and `unprotect` to remove it; both take the same
#     filters as prune, so a whole project is marked in one command. A marker
#     rather than a hard-coded list of ids because the protected body of work
#     grows, and a folder carries its own protection wherever it is moved or
#     archived.
#
# Safe to run twice and safe to interrupt: every removal and move is per-file
# and idempotent, an already-removed file is not an error, and an interrupted
# run leaves a partially pruned folder that the next identical run finishes.
#
# Exit status is 0 on success, 1 on a usage or runtime error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# shellcheck source=bin/fm-task-data-lib.sh
. "$SCRIPT_DIR/fm-task-data-lib.sh"

die() {
  printf 'fm-task-data: %s\n' "$*" >&2
  exit 1
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

IMAGE_EXTENSIONS='png jpg jpeg gif webp svg bmp tif tiff avif heic'

COMMAND=${1:-}
case "$COMMAND" in
  -h|--help|'') usage; exit 0 ;;
  list|prune|protect|unprotect) shift ;;
  *) die "unknown command '$COMMAND' (expected list, prune, protect, or unprotect)" ;;
esac

FILTER_PROJECTS=()
FILTER_TASKS=()
OLDER_THAN=
IS_IMAGES_ONLY=0
ARCHIVE_DIR=
IS_CONFIRMED=0
SHOULD_INCLUDE_PROTECTED=0
POSITIONAL=()

want_value=
for arg in "$@"; do
  if [ -n "$want_value" ]; then
    case "$arg" in
      --*) die "--$want_value requires a value" ;;
    esac
    case "$want_value" in
      project) FILTER_PROJECTS+=("$arg") ;;
      task) FILTER_TASKS+=("$arg") ;;
      older-than) OLDER_THAN=$arg ;;
      archive) ARCHIVE_DIR=$arg ;;
    esac
    want_value=
    continue
  fi
  case "$arg" in
    --project) want_value=project ;;
    --project=*) FILTER_PROJECTS+=("${arg#--project=}") ;;
    --task) want_value=task ;;
    --task=*) FILTER_TASKS+=("${arg#--task=}") ;;
    --older-than) want_value=older-than ;;
    --older-than=*) OLDER_THAN=${arg#--older-than=} ;;
    --archive) want_value=archive ;;
    --archive=*) ARCHIVE_DIR=${arg#--archive=} ;;
    --images-only) IS_IMAGES_ONLY=1 ;;
    --yes) IS_CONFIRMED=1 ;;
    --include-protected) SHOULD_INCLUDE_PROTECTED=1 ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown option '$arg'" ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
[ -z "$want_value" ] || die "--$want_value requires a value"

if [ -n "$OLDER_THAN" ]; then
  case "$OLDER_THAN" in
    ''|*[!0-9]*) die "--older-than takes a whole number of days (got '$OLDER_THAN')" ;;
  esac
fi

case "$COMMAND" in
  protect|unprotect)
    # Either explicit ids or filters, because a body of work worth protecting is
    # usually a whole project rather than a list someone has to keep up to date.
    [ "${#POSITIONAL[@]}" -gt 0 ] \
      || [ "${#FILTER_PROJECTS[@]}" -gt 0 ] \
      || [ "${#FILTER_TASKS[@]}" -gt 0 ] \
      || [ -n "$OLDER_THAN" ] \
      || die "$COMMAND requires at least one task id or filter"
    ;;
  *)
    [ "${#POSITIONAL[@]}" -eq 0 ] || die "unexpected argument '${POSITIONAL[0]}'"
    ;;
esac

# --- collection -------------------------------------------------------------

# A directory under the new layout is a task folder by position. A directory at
# the legacy top level is one only if it holds task content, because data/ also
# holds firstmate's own directories (handoff/ and friends) and this is the one
# tool that deletes things. An unrecognized folder is skipped, never removed.
# The protection marker counts as content, so marking an otherwise unrecognized
# folder is what makes it both visible here and permanently safe.
is_legacy_task_dir() {  # <dir>
  local dir=$1 name
  for name in brief.md report.md "$FM_TASK_DATA_MARKER" "$FM_TASK_DATA_PROTECTED"; do
    [ -e "$dir/$name" ] && return 0
  done
  return 1
}

# Every task data directory in both layouts, one per line.
#
# "all" includes legacy folders that hold no recognized task content. Only the
# protect path uses it: marking is not destructive, and a body of work can
# include folders that are neither a brief nor a report - the migration
# retrospective's own index is one - which must still be markable, and which
# become visible and permanently safe once marked.
all_task_dirs() {  # [all]
  local dir mode=${1:-recognized}
  [ -d "$DATA" ] || return 0
  {
    for dir in "$DATA"/*/; do
      [ -d "$dir" ] || continue
      dir=${dir%/}
      [ "$(basename -- "$dir")" != "$FM_TASK_DATA_SUBDIR" ] || continue
      [ "$mode" = all ] || is_legacy_task_dir "$dir" || continue
      printf '%s\n' "$dir"
    done
    for dir in "$DATA/$FM_TASK_DATA_SUBDIR"/*/*/; do
      [ -d "$dir" ] || continue
      printf '%s\n' "${dir%/}"
    done
  } | LC_ALL=C sort
}

list_contains() {  # <needle> <values...>
  local needle=$1 value
  shift
  for value in "$@"; do
    [ "$value" = "$needle" ] && return 0
  done
  return 1
}

# --task matches by shell glob, because a body of work is usually named by a
# shared id prefix rather than by its project: the migration reports on the
# captain's home are cvui-* inside front-client, which also holds unrelated
# tasks, and some legacy folders record no usable project at all. An exact id is
# its own glob, so plain ids keep working.
list_matches_pattern() {  # <needle> <patterns...>
  local needle=$1 pattern
  shift
  for pattern in "$@"; do
    # shellcheck disable=SC2254 # The pattern is a deliberate caller-supplied glob.
    case "$needle" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

matches_filters() {  # <dir> <task-id> <project>
  local dir=$1 id=$2 project=$3
  if [ "${#FILTER_PROJECTS[@]}" -gt 0 ]; then
    list_contains "$project" "${FILTER_PROJECTS[@]}" || return 1
  fi
  if [ "${#FILTER_TASKS[@]}" -gt 0 ]; then
    list_matches_pattern "$id" "${FILTER_TASKS[@]}" || return 1
  fi
  if [ -n "$OLDER_THAN" ]; then
    [ -n "$(find "$dir" -maxdepth 0 -mtime "+$OLDER_THAN" -print 2>/dev/null)" ] || return 1
  fi
  return 0
}

# --- protect / unprotect ----------------------------------------------------

# Marking is never destructive, so it reaches in-flight and already-marked
# folders too; only the prune path cares about those classifications.
set_protection() {  # <dir>
  if [ "$COMMAND" = protect ]; then
    : > "$1/$FM_TASK_DATA_PROTECTED"
    printf 'protected: %s\n' "$1"
  else
    rm -f -- "$1/$FM_TASK_DATA_PROTECTED"
    printf 'unprotected: %s\n' "$1"
  fi
}

if [ "$COMMAND" = protect ] || [ "$COMMAND" = unprotect ]; then
  marked=0
  for id in "${POSITIONAL[@]+"${POSITIONAL[@]}"}"; do
    dir=$(fm_task_data_find "$DATA" "$id") \
      || die "no task data directory for '$id' under $DATA"
    set_protection "$dir"
    marked=$((marked + 1))
  done
  if [ "${#POSITIONAL[@]}" -eq 0 ]; then
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      matches_filters "$dir" "$(basename -- "$dir")" \
        "$(fm_task_data_project_of_dir "$DATA" "$dir")" || continue
      set_protection "$dir"
      marked=$((marked + 1))
    done < <(all_task_dirs all)
  fi
  printf '%s folder(s) %sed.\n' "$marked" "$COMMAND"
  exit 0
fi

# Kilobytes a prune would actually reclaim from one folder.
reclaimable_kb() {  # <dir>
  local dir=$1 total=0 size
  if [ "$IS_IMAGES_ONLY" -eq 1 ]; then
    while read -r size _; do
      [ -n "$size" ] || continue
      total=$((total + size))
    done < <(image_files_of "$dir" -exec du -k -- {} + 2>/dev/null || true)
    printf '%s\n' "$total"
    return 0
  fi
  du -sk -- "$dir" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

image_files_of() {  # <dir> [find actions...]
  local dir=$1
  shift
  local -a expr=()
  local ext
  for ext in $IMAGE_EXTENSIONS; do
    [ "${#expr[@]}" -eq 0 ] || expr+=(-o)
    expr+=(-iname "*.$ext")
  done
  find "$dir" -type f \( "${expr[@]}" \) "$@"
}

human_kb() {  # <kilobytes>
  awk -v kb="$1" 'BEGIN {
    if (kb >= 1048576) { printf "%.1f GB\n", kb / 1048576 }
    else if (kb >= 1024) { printf "%.1f MB\n", kb / 1024 }
    else { printf "%d KB\n", kb }
  }'
}

# Rows are TAB-separated: project, task-id, dir, kilobytes, disposition.
SELECTED=()
SKIPPED=()
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  task_id=$(basename -- "$dir")
  task_project=$(fm_task_data_project_of_dir "$DATA" "$dir")
  matches_filters "$dir" "$task_id" "$task_project" || continue
  size_kb=$(reclaimable_kb "$dir")
  [ -n "$size_kb" ] || size_kb=0
  if [ -f "$STATE/$task_id.meta" ]; then
    SKIPPED+=("$task_project	$task_id	$dir	$size_kb	in flight: this task is still working and owns its folder")
    continue
  fi
  if [ -f "$dir/$FM_TASK_DATA_PROTECTED" ] && [ "$SHOULD_INCLUDE_PROTECTED" -eq 0 ]; then
    SKIPPED+=("$task_project	$task_id	$dir	$size_kb	protected: marked with $FM_TASK_DATA_PROTECTED (pass --include-protected to override)")
    continue
  fi
  SELECTED+=("$task_project	$task_id	$dir	$size_kb	")
done < <(all_task_dirs)

# --- reporting --------------------------------------------------------------

print_rows() {  # <heading> <rows...>
  local heading=$1 row project task_id dir size_kb note
  local last_project='' total=0 count=0
  shift
  [ "$#" -gt 0 ] || return 0
  printf '%s\n' "$heading"
  for row in "$@"; do
    IFS=$'\t' read -r project task_id dir size_kb note <<<"$row"
    if [ "$project" != "$last_project" ]; then
      printf '  %s\n' "$project"
      last_project=$project
    fi
    printf '    %-40s %10s  %s\n' "$task_id" "$(human_kb "$size_kb")" "$note"
    total=$((total + size_kb))
    count=$((count + 1))
  done
  printf '  %s folder(s), %s\n\n' "$count" "$(human_kb "$total")"
}

if [ "$IS_IMAGES_ONLY" -eq 1 ]; then
  SIZE_LABEL="images"
else
  SIZE_LABEL="folder"
fi

if [ "$COMMAND" = list ]; then
  print_rows "Task data under $DATA ($SIZE_LABEL size):" \
    "${SELECTED[@]+"${SELECTED[@]}"}"
  print_rows "Skipped:" "${SKIPPED[@]+"${SKIPPED[@]}"}"
  exit 0
fi

# --- prune ------------------------------------------------------------------

if [ -n "$ARCHIVE_DIR" ]; then
  ACTION_LABEL="archive into $ARCHIVE_DIR"
else
  ACTION_LABEL="remove"
fi
if [ "$IS_IMAGES_ONLY" -eq 1 ]; then
  ACTION_LABEL="$ACTION_LABEL (images only; every other file stays)"
fi

if [ "$IS_CONFIRMED" -eq 1 ]; then
  print_rows "About to $ACTION_LABEL:" "${SELECTED[@]+"${SELECTED[@]}"}"
else
  print_rows "DRY RUN - would $ACTION_LABEL (nothing is changed; pass --yes to do it):" \
    "${SELECTED[@]+"${SELECTED[@]}"}"
fi
print_rows "Skipped:" "${SKIPPED[@]+"${SKIPPED[@]}"}"

if [ "${#SELECTED[@]}" -eq 0 ]; then
  echo "fm-task-data: nothing selected."
  exit 0
fi

if [ "$IS_CONFIRMED" -eq 0 ]; then
  echo "fm-task-data: dry run, nothing was changed."
  exit 0
fi

# Move one file under <dir> to the same relative place under the archive root.
archive_file() {  # <task-dir> <archive-root> <file>
  local dir=$1 root=$2 file=$3 relative dest
  relative=${file#"$dir"/}
  dest="$root/$relative"
  mkdir -p -- "$(dirname -- "$dest")"
  mv -f -- "$file" "$dest"
}

for row in "${SELECTED[@]}"; do
  IFS=$'\t' read -r project task_id dir size_kb note <<<"$row"
  archive_root=
  if [ -n "$ARCHIVE_DIR" ]; then
    archive_root="$ARCHIVE_DIR/$project/$task_id"
    mkdir -p -- "$archive_root"
  fi
  if [ "$IS_IMAGES_ONLY" -eq 1 ]; then
    while IFS= read -r -d '' file; do
      if [ -n "$archive_root" ]; then
        archive_file "$dir" "$archive_root" "$file"
      else
        rm -f -- "$file"
      fi
    done < <(image_files_of "$dir" -print0)
    printf 'pruned images: %s\n' "$dir"
    continue
  fi
  if [ -n "$archive_root" ]; then
    while IFS= read -r -d '' file; do
      archive_file "$dir" "$archive_root" "$file"
    done < <(find "$dir" -type f -print0)
    # Interrupted runs can leave the source half-moved; the next identical run
    # finishes it, and only an emptied tree is discarded.
    find "$dir" -depth -type d -empty -exec rmdir -- {} + 2>/dev/null || true
    printf 'archived: %s -> %s\n' "$dir" "$archive_root"
  else
    rm -rf -- "$dir"
    printf 'removed: %s\n' "$dir"
  fi
done
