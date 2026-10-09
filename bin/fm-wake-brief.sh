#!/usr/bin/env bash
# fm-wake-brief.sh - drain the wake queue and print a compact brief of it,
# written by one model call (Haiku or Sonnet), so a handling turn reads a few lines instead
# of the raw drain plus every status log and report it points at.
#
# Usage:
#   fm-wake-brief.sh                 drain once and print the brief
#   fm-wake-brief.sh <drain args>    any argument (such as --ack-through)
#                                    runs bin/fm-wake-drain.sh with exactly
#                                    those arguments and nothing else
#
# The drain runs exactly once, in this home and with the caller's environment,
# so its side effects (claiming, presenting, and cursor-advancing) are the same
# as a plain drain. Its output is then rewritten as:
#   1. one header line, then one line per queued wake row:
#        #<seq> <kind> <who>: <what> | decision needed: y|n
#      <who> is derived from the row by this script; only <what> and the
#      model's y/n come from the model.
#   2. every other drain section and notice, verbatim (OPEN DECISIONS,
#      UNREAD STATUS, STATUS OUTCOME BACKSTOP, RECORD DIVERGENCE, BRANCH
#      OUTCOMES, and skip notices), minus its command lines.
#   3. the acknowledgement commands, copied verbatim from the raw drain output
#      by deterministic text extraction: every WAKE_ACK_REQUIRED line and every
#      `bin/fm-branch-outcome.sh mark-processed` line. The model never sees a
#      reason to write them and a model line naming one is rejected.
#
# Safety:
#   - A row whose kind, key, payload, or newest status line names a decision,
#     blocker, failure, credential, review, PR, or report is always printed with
#     `decision needed: y`, whatever the model said; every stale row is too.
#   - Raw fallback: when the drain exits non-zero, presents no queued row, no
#     model call succeeds within FM_WAKE_BRIEF_TIMEOUT seconds (default 90), or
#     the model output does not account for every queued sequence exactly once in
#     the required line shape, the raw drain stdout and stderr are printed
#     unchanged after one `wake brief: ... raw drain output follows` notice on
#     stderr.
#   - The model input is the presented rows, the last FM_WAKE_BRIEF_STATUS_LINES
#     (default 3) lines of each signalled status log, and at most three report
#     files the rows or drain sections reference that live under
#     $FM_HOME/data/, each cut to 6000 bytes.
#
# Model choice is deterministic, made by this script before any call: Haiku
# (claude-haiku-4-5-20251001) only when every queued row is mechanical, that is
# no row is forced to `decision needed: y` by the Safety rule above; Sonnet
# then backs up a failed or unusable Haiku brief. When any row is forced to y
# the whole brief is written by Sonnet alone, with the raw drain as its only
# fallback. Never Fable or Opus. The model runs from an
# empty scratch directory with no setting sources, tools, MCP servers, or
# session persistence, so no project or user hook fires and no tool can act.
# FM_WAKE_BRIEF_CLAUDE names the claude binary (default `claude`; tests stub
# it).
#
# bin/fm-wake-drain.sh stays the authoritative raw path: run it directly when
# the brief is not enough. Queued rows stay queued until the printed
# --ack-through command runs, so a raw drain re-presents them.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAIN="$SCRIPT_DIR/fm-wake-drain.sh"

if [ "$#" -gt 0 ]; then
  exec "$DRAIN" "$@"
fi

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

CLAUDE_BIN=${FM_WAKE_BRIEF_CLAUDE:-claude}
TIMEOUT=${FM_WAKE_BRIEF_TIMEOUT:-90}
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=90 ;; esac
STATUS_LINES=${FM_WAKE_BRIEF_STATUS_LINES:-3}
case "$STATUS_LINES" in ''|*[!0-9]*|0) STATUS_LINES=3 ;; esac
REPORT_MAX_BYTES=6000
REPORT_MAX_COUNT=3
MUST_FLAG_RE='needs-decision|blocked|fail|error|credential|login|auth|ask-user|review|merge|conflict|stuck|captain|report|https://[^[:space:]]+/pull/[0-9]+'

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-wake-brief.XXXXXX") || exec "$DRAIN"
trap 'rm -rf -- "$WORK"' EXIT

"$DRAIN" > "$WORK/out" 2> "$WORK/err"
DRAIN_RC=$?

raw_fallback() {  # <reason>
  printf 'wake brief: %s; raw drain output follows\n' "$1" >&2
  cat "$WORK/out"
  cat "$WORK/err" >&2
  exit "$DRAIN_RC"
}

[ "$DRAIN_RC" -eq 0 ] || raw_fallback "the drain exited $DRAIN_RC"

# A queued row is the drain's five tab-separated fields led by epoch and sequence.
awk -F '\t' 'NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/' "$WORK/out" > "$WORK/rows"
[ -s "$WORK/rows" ] || raw_fallback "no queued wake row to summarize"

# Deterministic command extraction; these lines are printed verbatim, last.
{
  grep -h '^WAKE_ACK_REQUIRED: ' "$WORK/err" "$WORK/out"
  grep -h 'bin/fm-branch-outcome\.sh mark-processed' "$WORK/out"
} > "$WORK/commands"
grep -q '^WAKE_ACK_REQUIRED: ' "$WORK/commands" || raw_fallback "the drain printed no WAKE_ACK_REQUIRED command"

awk -F '\t' '!(NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/)' "$WORK/out" \
  | grep -v -e '^WAKE_ACK_REQUIRED: ' -e 'bin/fm-branch-outcome\.sh mark-processed' > "$WORK/sections"
grep -v '^WAKE_ACK_REQUIRED: ' "$WORK/err" > "$WORK/notices"

# Per-row facts the script owns: who, the must-flag verdict, and model input.
: > "$WORK/facts"
: > "$WORK/input"
: > "$WORK/refs"
while IFS=$(printf '\t') read -r _epoch seq kind key payload; do
  who=$key
  tail_text=
  case "$kind" in
    signal)
      case "$key" in
        *.status)
          who=${key##*/}
          who=${who%.status}
          if [ -f "$key" ] && [ -r "$key" ]; then
            tail_text=$(tail -n "$STATUS_LINES" "$key" 2>/dev/null | cut -c1-400)
          fi
          ;;
      esac
      ;;
    heartbeat) who=fleet ;;
  esac
  who=$(printf '%s' "$who" | cut -c1-60)
  newest=$(printf '%s\n' "$tail_text" | tail -n 1)
  flag=n
  if [ "$kind" = stale ] \
    || printf '%s\n%s\n%s\n%s\n' "$kind" "$key" "$payload" "$newest" | grep -Eiq "$MUST_FLAG_RE"; then
    flag=y
  fi
  printf '%s\t%s\t%s\t%s\n' "$seq" "$kind" "$who" "$flag" >> "$WORK/facts"
  {
    printf 'EVENT S%s kind=%s who=%s required-decision=%s\n' "$seq" "$kind" "$who" "$flag"
    printf '  key: %s\n  payload: %s\n' "$key" "$payload"
    if [ -n "$tail_text" ]; then
      printf '  status log, newest last:\n'
      printf '%s\n' "$tail_text" | sed 's/^/    /'
    fi
  } >> "$WORK/input"
  printf '%s\n%s\n%s\n' "$key" "$payload" "$tail_text" >> "$WORK/refs"
done < "$WORK/rows"

cat "$WORK/sections" >> "$WORK/refs"
# Referenced reports under $FM_HOME/data/, absolute or home-relative.
grep -Eo '[^][[:space:]"'"'"'`()<>]*report[^][[:space:]"'"'"'`()<>]*\.md' "$WORK/refs" 2>/dev/null \
  | awk '!seen[$0]++' > "$WORK/report-paths" || true
reports=0
while IFS= read -r path; do
  [ "$reports" -lt "$REPORT_MAX_COUNT" ] || break
  case "$path" in /*) ;; *) path="$FM_HOME/${path#./}" ;; esac
  case "$path" in "$FM_HOME"/data/*) ;; *) continue ;; esac
  case "$path" in *..*) continue ;; esac
  [ -f "$path" ] && [ -r "$path" ] || continue
  {
    printf 'REPORT %s (first %s bytes):\n' "$path" "$REPORT_MAX_BYTES"
    head -c "$REPORT_MAX_BYTES" "$path"
    printf '\n'
  } >> "$WORK/input"
  reports=$((reports + 1))
done < "$WORK/report-paths"

if [ -s "$WORK/sections" ]; then
  {
    printf 'OTHER DRAIN SECTIONS (context only; they are shown to the reader verbatim):\n'
    head -c 8000 "$WORK/sections"
  } >> "$WORK/input"
fi

SYSTEM_PROMPT='You condense a supervisor wake queue. For every EVENT S<n> in the input write exactly one line, in input order, and nothing else:
S<n> | <what happened and what the supervisor must do, at most 25 words> | decision: <y or n>
Use y when the event needs a decision, approval, review, merge, credential, or unblocking, or reports a failure, a blocker, a review-ready PR, or a finished report; otherwise n. When an EVENT says required-decision=y, answer y.
Keep every PR URL, task name, and decision key that matters, verbatim. Summarize a referenced report in the same line.
Never write commands, acknowledgements, headings, blank lines, code fences, or any other text.'

# Haiku only for an all-mechanical queue; any decision-bearing row means Sonnet.
if awk -F '\t' '$4 == "y" { found = 1 } END { exit !found }' "$WORK/facts"; then
  MODELS="sonnet"
else
  MODELS="claude-haiku-4-5-20251001 sonnet"
fi

mkdir "$WORK/cwd" || raw_fallback "could not create the model scratch directory"

# validate <model-output> <brief-out>: one well-formed line per queued sequence.
validate() {
  awk -F '\t' -v out="$2" '
    FNR == NR { order[++n] = $1; kind[$1] = $2; who[$1] = $3; flag[$1] = $4; next }
    /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line !~ /^S[0-9]+ \| .+ \| decision: [yn]$/) { bad = 1; exit }
      if (line ~ /WAKE_ACK_REQUIRED|--ack-through|mark-processed/) { bad = 1; exit }
      seq = line; sub(/ .*/, "", seq); sub(/^S/, "", seq)
      if (!(seq in kind) || (seq in got)) { bad = 1; exit }
      answer = substr(line, length(line), 1)
      what = line; sub(/^S[0-9]+ \| /, "", what); sub(/ \| decision: [yn]$/, "", what)
      if (length(what) > 300) what = substr(what, 1, 297) "..."
      got[seq] = what; ans[seq] = answer
    }
    END {
      if (bad) exit 1
      for (i = 1; i <= n; i++) if (!(order[i] in got)) exit 1
      for (i = 1; i <= n; i++) {
        s = order[i]
        d = (flag[s] == "y" || ans[s] == "y") ? "y" : "n"
        printf "#%s %s %s: %s | decision needed: %s\n", s, kind[s], who[s], got[s], d > out
      }
    }
  ' "$WORK/facts" "$1"
}

USED_MODEL=
for model in $MODELS; do
  rm -f "$WORK/model.out" "$WORK/brief"
  if (cd "$WORK/cwd" && fm_run_timed "$TIMEOUT" "$CLAUDE_BIN" -p --model "$model" \
      --setting-sources "" --tools "" --strict-mcp-config --no-session-persistence \
      --system-prompt "$SYSTEM_PROMPT") < "$WORK/input" > "$WORK/model.out" 2>/dev/null \
    && validate "$WORK/model.out" "$WORK/brief"; then
    USED_MODEL=$model
    break
  fi
done
[ -n "$USED_MODEL" ] || raw_fallback "no model returned a valid brief"

printf 'WAKE BRIEF (%s queued row(s), condensed by %s; bin/fm-wake-drain.sh re-presents them raw until acknowledged):\n' \
  "$(awk 'END { print NR }' "$WORK/facts")" "$USED_MODEL"
cat "$WORK/brief"
cat "$WORK/sections"
cat "$WORK/notices" >&2
cat "$WORK/commands"
exit 0
