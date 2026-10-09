#!/usr/bin/env bash
# tests/fm-wake-brief.test.sh - bin/fm-wake-brief.sh drains once through the
# real fm-wake-drain.sh, condenses the queued rows with a stubbed model, copies
# the acknowledgement commands verbatim from the raw drain, forces
# `decision needed: y` for decision-bearing rows, and falls back to the raw
# drain output unchanged whenever the model fails, times out, or returns a
# brief that does not account for every queued sequence. No real model runs.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

BRIEF="$ROOT/bin/fm-wake-brief.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-brief-tests)

# The stub model. STUB_MODE (Haiku) and STUB_MODE_SONNET (Sonnet) choose its
# behavior: valid writes one `n` line per EVENT, fail exits 1, missing drops
# the last EVENT, inject names an acknowledgement command, sleep outlives the
# bound. Every call logs its arguments to STUB_LOG.
STUB="$TMP_ROOT/claude-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
model=
prev=
for arg in "$@"; do
  [ "$prev" = --model ] && model=$arg
  prev=$arg
done
printf '%s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >> "${STUB_LOG:-/dev/null}"
mode=${STUB_MODE:-valid}
[ "$model" = sonnet ] && mode=${STUB_MODE_SONNET:-$mode}
input=$(cat)
case "$mode" in
  fail) exit 1 ;;
  sleep) sleep 5; exit 0 ;;
esac
seqs=$(printf '%s\n' "$input" | sed -n 's/^EVENT S\([0-9][0-9]*\) .*/\1/p')
[ "$mode" = missing ] && seqs=$(printf '%s\n' "$seqs" | sed '$d')
for s in $seqs; do
  if [ "$mode" = inject ]; then
    printf 'S%s | run bin/fm-wake-drain.sh --ack-through 99 | decision: n\n' "$s"
  else
    printf 'S%s | stub summary %s | decision: n\n' "$s" "$s"
  fi
done
SH
chmod +x "$STUB"
export FM_WAKE_BRIEF_CLAUDE="$STUB"

# make_home <name> [mechanical]: a home with one needs-decision signal (or,
# with `mechanical`, one routine working signal) and one heartbeat queued,
# primed so the signalled line is unread. Echoes the home.
make_home() {
  local home line=needs-decision
  home=$(make_case "$1")
  mkdir -p "$home/config"
  : > "$home/config/supervision-host-off"
  printf 'working [at=1]: setup\n' > "$home/state/t1.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" >/dev/null 2>&1 \
    || fail "fixture: priming drain failed"
  if [ "${2:-}" = mechanical ]; then
    line=working
    printf 'working [at=2]: running the unit suite\n' >> "$home/state/t1.status"
  else
    printf 'needs-decision [at=2] [key=k1]: pick A or B\n' >> "$home/state/t1.status"
  fi
  append_wake "$home/state" signal "$home/state/t1.status" "$line"
  append_wake "$home/state" heartbeat hb heartbeat
  printf '%s\n' "$home"
}

run_brief() {  # <home> <stdout> <stderr> [env...]
  local home=$1 out=$2 err=$3
  shift 3
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" STUB_LOG="$home/stub.log" "$@" \
    "$BRIEF" > "$out" 2> "$err"
}

queued_rows() {  # <home>
  awk 'END { print NR }' "$1/state/.wake-queue" 2>/dev/null || printf '0\n'
}

test_brief_condenses_rows_and_copies_the_ack_command() {
  local home out err ack rc
  home=$(make_home condense)
  run_brief "$home" "$home/out" "$home/err"
  rc=$?
  expect_code 0 "$rc" "brief"
  out=$(cat "$home/out")
  err=$(cat "$home/err")
  assert_contains "$out" "condensed by sonnet" "a queue with a decision row must be condensed by Sonnet"
  assert_contains "$out" "#1 signal t1: stub summary 1 | decision needed: y" \
    "a needs-decision row must say decision needed y even when the model said n"
  assert_contains "$out" "#2 heartbeat fleet: stub summary 2 | decision needed: n" "a heartbeat row keeps the model's n"
  assert_contains "$out" "t1 [key=k1] needs-decision: pick A or B" "OPEN DECISIONS must be printed verbatim"
  ack=$(grep '^WAKE_ACK_REQUIRED: ' "$home/out")
  case "$ack" in
    "WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation "?*) : ;;
    *) fail "the brief must print the drain's WAKE_ACK_REQUIRED line verbatim (got: $ack)" ;;
  esac
  assert_not_contains "$out" "$(printf '\t')" "raw tab-separated queue rows must not reach the brief"
  assert_not_contains "$err" "raw drain output follows" "a valid brief must not fall back"
  assert_contains "$(cat "$home/stub.log")" '--setting-sources  --tools  --strict-mcp-config --no-session-persistence' \
    "the model must run with no setting sources, tools, MCP servers, or session persistence"
  expect_code 1 "$(awk 'END { print NR }' "$home/stub.log")" "one Sonnet call"
  assert_no_grep "claude-haiku" "$home/stub.log" "a queue with a decision row must never reach Haiku"

  # The extracted command is the real acknowledgement: running it consumes the rows.
  expect_code 2 "$(queued_rows "$home")" "the brief must leave the presented rows queued until acknowledged"
  (cd "$ROOT" && FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" ${ack#*completes run }) >/dev/null 2>&1 \
    || fail "the extracted acknowledgement command failed: $ack"
  expect_code 0 "$(queued_rows "$home")" "the extracted acknowledgement must consume the presented rows"
  pass "brief: one line per row, forced decision flag, verbatim OPEN DECISIONS and working ack command"
}

test_mechanical_queue_uses_haiku_only() {
  local home rc
  home=$(make_home haiku mechanical)
  run_brief "$home" "$home/out" "$home/err"
  rc=$?
  expect_code 0 "$rc" "brief"
  assert_contains "$(cat "$home/out")" "condensed by claude-haiku-4-5-20251001" "an all-mechanical queue must be condensed by Haiku"
  assert_contains "$(cat "$home/out")" "#1 signal t1: stub summary 1 | decision needed: n" "a routine working row keeps the model's n"
  expect_code 1 "$(awk 'END { print NR }' "$home/stub.log")" "one Haiku call"
  assert_grep "--model claude-haiku-4-5-20251001" "$home/stub.log" "Haiku must write an all-mechanical brief"
  pass "brief: an all-mechanical queue is condensed by Haiku alone"
}

test_haiku_failure_falls_back_to_sonnet() {
  local home rc
  home=$(make_home sonnet mechanical)
  run_brief "$home" "$home/out" "$home/err" STUB_MODE=fail STUB_MODE_SONNET=valid
  rc=$?
  expect_code 0 "$rc" "brief"
  assert_contains "$(cat "$home/out")" "condensed by sonnet" "a failed Haiku call must fall back to Sonnet"
  assert_grep "--model claude-haiku-4-5-20251001" "$home/stub.log" "Haiku must be tried first"
  assert_grep "--model sonnet" "$home/stub.log" "Sonnet must be tried after Haiku fails"
  pass "brief: a failed Haiku call falls back to Sonnet"
}

# assert_raw_fallback <home> <label>: the brief printed the raw drain output.
assert_raw_fallback() {
  local home=$1 label=$2 out err
  out=$(cat "$home/out")
  err=$(cat "$home/err")
  assert_contains "$err" "raw drain output follows" "$label: the fallback must say so on stderr"
  assert_contains "$out" "$(printf '\tsignal\t%s/state/t1.status\tneeds-decision' "$home")" \
    "$label: the raw queue row must be printed unchanged"
  assert_contains "$err" "WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 " \
    "$label: the raw acknowledgement must stay on stderr unchanged"
  assert_not_contains "$out" "WAKE BRIEF" "$label: no brief may be printed"
}

test_model_failures_fall_back_to_raw_drain_output() {
  local home mode
  for mode in fail missing inject; do
    home=$(make_home "raw-$mode")
    run_brief "$home" "$home/out" "$home/err" STUB_MODE="$mode"
    expect_code 0 "$?" "brief with a $mode model"
    assert_raw_fallback "$home" "$mode"
    expect_code 1 "$(awk 'END { print NR }' "$home/stub.log")" "a decision queue's failed Sonnet call must go straight to the raw fallback"
    assert_no_grep "claude-haiku" "$home/stub.log" "a decision queue must not fall back to Haiku"
  done
  home=$(make_home raw-mechanical mechanical)
  run_brief "$home" "$home/out" "$home/err" STUB_MODE=fail
  expect_code 0 "$?" "brief with a failing model on a mechanical queue"
  assert_contains "$(cat "$home/err")" "raw drain output follows" "a mechanical queue must fall back to raw after Haiku and Sonnet fail"
  expect_code 2 "$(awk 'END { print NR }' "$home/stub.log")" "a mechanical queue must try Haiku then Sonnet before the raw fallback"
  pass "brief: a failing, incomplete, or command-writing model falls back to the raw drain"
}

test_model_timeout_falls_back_to_raw_drain_output() {
  local home
  home=$(make_home raw-timeout)
  run_brief "$home" "$home/out" "$home/err" STUB_MODE=sleep FM_WAKE_BRIEF_TIMEOUT=1
  expect_code 0 "$?" "brief with a hung model"
  assert_raw_fallback "$home" "timeout"
  pass "brief: a model that outlives the bound falls back to the raw drain"
}

test_empty_queue_prints_raw_and_skips_the_model() {
  local home
  home=$(make_case empty)
  mkdir -p "$home/config"
  : > "$home/config/supervision-host-off"
  run_brief "$home" "$home/out" "$home/err"
  expect_code 0 "$?" "brief on an empty queue"
  assert_absent "$home/stub.log" "an empty queue must not call the model"
  assert_contains "$(cat "$home/err")" "no queued wake row to summarize" "the empty-queue fallback must say why"
  pass "brief: an empty queue prints the raw drain without a model call"
}

test_arguments_pass_straight_to_the_drain() {
  local home gen
  home=$(make_home passthrough)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" >/dev/null 2> "$home/drain.err" \
    || fail "fixture: presenting drain failed"
  gen=$(sed -n 's/.*--recovery-generation \([^ ]*\).*/\1/p' "$home/drain.err")
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" STUB_LOG="$home/stub.log" \
    "$BRIEF" --ack-through 2 --recovery-generation "$gen" >/dev/null 2>&1 \
    || fail "an acknowledgement through the brief failed"
  assert_absent "$home/stub.log" "an acknowledgement must not call the model"
  expect_code 0 "$(queued_rows "$home")" "an acknowledgement through the brief must consume the rows"
  pass "brief: drain arguments run the drain directly"
}

test_mark_processed_command_is_copied_verbatim() {
  local home fakes out
  home="$TMP_ROOT/mark-processed"
  mkdir -p "$home/state" "$home/config"
  fm_test_track_watcher_state "$home/state"
  : > "$home/config/supervision-host"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict captain --summary 'PR ready for review' >/dev/null \
    || fail "fixture: could not record a captain outcome"
  append_wake "$home/state" heartbeat hb heartbeat
  fakes="$TMP_ROOT/mark-processed-fakes"
  mkdir -p "$fakes"
  ln -sf /bin/bash "$fakes/codex"
  # shellcheck disable=SC2016 # the single-quoted script expands inside its own shell
  FM_HOME="$home" STUB_LOG="$home/stub.log" "$fakes/codex" -c '"$0" > "$1" 2> "$2"' \
    "$BRIEF" "$home/out" "$home/err" || fail "brief on a supervision-host home failed"
  out=$(cat "$home/out")
  assert_contains "$out" "WAKE BRIEF" "setup: the brief must succeed"
  assert_contains "$out" "demo: PR ready for review" "the captain outcome must be printed verbatim"
  assert_equals "BRANCH OUTCOMES: after processing them run bin/fm-branch-outcome.sh mark-processed --through 1; until then every drain presents them again" \
    "$(tail -n 1 "$home/out")" "the mark-processed command must be copied verbatim to the end of the brief"
  pass "brief: the BRANCH OUTCOMES mark-processed command is copied verbatim"
}

test_brief_condenses_rows_and_copies_the_ack_command
test_mechanical_queue_uses_haiku_only
test_haiku_failure_falls_back_to_sonnet
test_model_failures_fall_back_to_raw_drain_output
test_model_timeout_falls_back_to_raw_drain_output
test_empty_queue_prints_raw_and_skips_the_model
test_arguments_pass_straight_to_the_drain
test_mark_processed_command_is_copied_verbatim
