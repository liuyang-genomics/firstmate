#!/usr/bin/env bash
# fm-hold-expiry.sh - raise one wake when a captain hold's --until date arrives.
#
# Usage:
#   fm-hold-expiry.sh scan
#
# `bin/fm-captain-hold.sh hold --until <date>` stores a deferral date and
# tasks-axi stops treating the task as held once that date passes, so nothing
# else tells firstmate the deferral is over and a held-task cadence would
# silently never resurface. `scan` reads open captain-held tasks through
# bin/fm-tasks-axi.sh, and for each whose hold-until is today or earlier it
# appends one `check` wake keyed `hold-expired-<id>` and prints
# `actionable: <payload>`. The date it raised is recorded in
# `$STATE/.hold-expired-<id>`, so later scans stay silent after the wake is
# acknowledged; re-holding the task with a new --until date raises a new wake.
# The watcher poll runs this beside bin/fm-inactive-reconcile.sh. It prints
# nothing and exits 0 when no deferral has arrived.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME STATE

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

scan() {
  local today rows id until marker key payload rc=0
  today=$(date -u +%Y-%m-%d)
  rows=$("$SCRIPT_DIR/fm-tasks-axi.sh" list --fields held,hold_kind,hold_until 2>/dev/null) || return 0
  # Row shape: id,state,kind,repo,title,held,hold_kind,hold_until. The title may
  # hold commas, so the trailing three fields are read from the end of the line.
  rows=$(printf '%s\n' "$rows" | awk -F, -v today="$today" '
    NF >= 8 && $2 != "done" && $(NF-2) == "no" && $(NF-1) == "captain" \
      && $NF ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ && $NF <= today {
      gsub(/^[[:space:]]+/, "", $1)
      print $1 "\t" $NF
    }')
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r id until; do
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    marker="$STATE/.hold-expired-$id"
    [ "$(cat "$marker" 2>/dev/null || true)" = "$until" ] && continue
    key="hold-expired-$id"
    payload="check: hold-expired $id (deferred until $until)"
    fm_wake_append check "$key" "$payload" || { rc=2; continue; }
    printf '%s\n' "$until" > "$marker" || rc=2
    printf 'actionable: %s\n' "$payload"
  done <<EOF2
$rows
EOF2
  return "$rc"
}

case "${1:-}" in
  scan) scan ;;
  *) echo "usage: fm-hold-expiry.sh scan" >&2; exit 64 ;;
esac
