#!/usr/bin/env bash
# Behavioral coverage for the wake raised when a captain hold's --until date arrives.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPIRY="$ROOT/bin/fm-hold-expiry.sh"
HOLD="$ROOT/bin/fm-captain-hold.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-hold-expiry)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() { # <name>
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
}

in_home() { # <command> [args...]
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$@"
}

date_offset() { # <days> (UTC, negative for the past)
  date -u -v"$1"d +%Y-%m-%d 2>/dev/null || date -u -d "$1 days" +%Y-%m-%d
}

add_held() { # <id> <until>
  in_home "$ROOT/bin/fm-tasks-axi.sh" add "$1" "routine $1" --kind work >/dev/null || fail "add $1"
  in_home "$HOLD" hold "$1" --reason "daily cadence" --until "$2" >/dev/null || fail "hold $1"
}

queue_rows() { # <task-id>
  local n
  n=$(grep -c "hold-expired-$1" "$HOME_DIR/state/.wake-queue" 2>/dev/null)
  printf '%s\n' "${n:-0}"
}

test_future_hold_raises_nothing() {
  make_home future
  add_held routine-a "$(date_offset +3)"
  [ -z "$(in_home "$EXPIRY" scan)" ] || fail "a future deferral raised a wake"
  [ "$(queue_rows routine-a)" = 0 ] || fail "a future deferral was queued"
  pass "a deferral still in the future raises no wake"
}

test_expired_hold_raises_exactly_one_wake() {
  local out
  make_home expired
  add_held routine-b "$(date_offset -1)"
  out=$(in_home "$EXPIRY" scan) || fail "scan failed"
  assert_contains "$out" "hold-expired routine-b"
  [ "$(queue_rows routine-b)" = 1 ] || fail "expected exactly one queued wake"
  [ -z "$(in_home "$EXPIRY" scan)" ] || fail "a repeat scan raised a second wake"
  [ "$(queue_rows routine-b)" = 1 ] || fail "a repeat scan queued a second wake"
  pass "an expired deferral raises exactly one wake"
}

test_acknowledged_wake_stays_quiet_until_reheld() {
  make_home acked
  add_held routine-c "$(date_offset -2)"
  in_home "$EXPIRY" scan >/dev/null
  : > "$HOME_DIR/state/.wake-queue"
  [ -z "$(in_home "$EXPIRY" scan)" ] || fail "an acknowledged deferral raised again"
  in_home "$HOLD" hold routine-c --reason "daily cadence" --until "$(date_offset -1)" >/dev/null || fail "re-hold"
  assert_contains "$(in_home "$EXPIRY" scan)" "hold-expired routine-c"
  pass "an acknowledged deferral stays quiet and a re-hold raises a fresh wake"
}

test_closed_task_raises_nothing() {
  make_home closed
  add_held routine-d "$(date_offset -1)"
  in_home "$ROOT/bin/fm-tasks-axi.sh" done routine-d >/dev/null || fail "done"
  [ -z "$(in_home "$EXPIRY" scan)" ] || fail "a closed task raised a wake"
  pass "a closed task raises no wake"
}

test_watcher_poll_raises_the_wake() {
  local pid i
  make_home watcher
  add_held routine-e "$(date_offset -1)"
  in_home env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$HOME_DIR/watch.out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ "$(queue_rows routine-e)" = 0 ] || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(queue_rows routine-e)" = 1 ] || fail "the watcher poll did not queue the wake: $(cat "$HOME_DIR/watch.out")"
  pass "the real watcher poll raises the wake"
}

test_future_hold_raises_nothing
test_expired_hold_raises_exactly_one_wake
test_acknowledged_wake_stays_quiet_until_reheld
test_closed_task_raises_nothing
test_watcher_poll_raises_the_wake

echo "all hold expiry tests passed"
