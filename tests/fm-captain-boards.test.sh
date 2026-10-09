#!/usr/bin/env bash
# Behavior tests for the captain-boards skill scripts: the board scaffold
# generator, the index-completeness check, and the Range-capable server.
# Every case runs against both the internal (.agents/skills) and the public
# (skills/) copy, since the two are deliberately independent files.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null || fail "python3 is required"
TMP_ROOT=$(fm_test_tmproot captain-boards)

write_spec() {  # <root> <json>
  printf '%s\n' "$2" >"$1/board.json"
}

run_suite() {  # <skill-dir> <tag>
  local skill=$1 tag=$2 scaffold check root out rc
  scaffold="$skill/scripts/board_scaffold.py"
  check="$skill/scripts/board_check.py"
  root="$TMP_ROOT/$tag/site"

  # init creates the spec and an index with the Waiting-on-you box, and is clean.
  out=$(python3 "$scaffold" init "$root" --title "Board" 2>&1) || fail "$tag: init failed: $out"
  assert_present "$root/board.json" "$tag: init writes board.json"
  assert_grep 'id="waiting"' "$root/index.html" "$tag: index opens with the Waiting-on-you box"
  assert_grep 'Nothing waiting on you.' "$root/index.html" "$tag: empty Waiting-on-you says so"
  out=$(python3 "$check" "$root" 2>&1) || fail "$tag: fresh board should pass the check: $out"
  pass "$tag: init builds a complete empty board"

  # build renders cards, stubs missing area pages, and keeps the Waiting box first.
  write_spec "$root" '{"title":"Board","waiting":[{"text":"Pick a narrator","link":"/casting/"}],
    "updates":[{"date":"2026-01-01","text":"older"},{"date":"2026-02-01","text":"newer","link":"/production/"}],
    "areas":[{"slug":"casting","name":"Voice Pick","alt":"配音选角","detail":"candidates and picks"},
             {"slug":"production","name":"Production","detail":"per-chapter status"}],
    "links":[{"path":"READ-THIS.txt","name":"Read This","detail":"how this site is served"}],
    "assets":["static/"]}'
  printf 'served on the LAN\n' >"$root/READ-THIS.txt"
  mkdir -p "$root/static"
  out=$(python3 "$scaffold" build "$root" 2>&1) || fail "$tag: build failed: $out"
  assert_present "$root/casting/index.html" "$tag: build stubs a missing area page"
  assert_grep 'Voice Pick / 配音选角' "$root/index.html" "$tag: card shows the bilingual name"
  assert_grep 'Pick a narrator' "$root/index.html" "$tag: waiting item rendered"
  local html waiting_at areas_at newer_at older_at
  html=$(cat "$root/index.html")
  waiting_at=${html%%id=\"waiting\"*}; areas_at=${html%%<h2>Areas*}
  newer_at=${html%%newer*}; older_at=${html%%older*}
  [ "${#waiting_at}" -lt "${#areas_at}" ] || fail "$tag: Waiting-on-you must precede the area cards"
  [ "${#newer_at}" -lt "${#older_at}" ] || fail "$tag: updates must be newest first"
  out=$(python3 "$check" "$root" --record 2>&1) || fail "$tag: built board should pass: $out"
  assert_grep '/casting/index.html' "$root/board-pages.txt" "$tag: --record writes the page ledger"
  pass "$tag: build renders spec, stubs areas, and passes the check"

  # build never overwrites an existing area page.
  printf '<html><body>owner content <a href="/">home</a></body></html>\n' >"$root/casting/index.html"
  python3 "$scaffold" build "$root" >/dev/null 2>&1 || fail "$tag: rebuild failed"
  assert_grep 'owner content' "$root/casting/index.html" "$tag: existing area page kept as-is"
  pass "$tag: build leaves existing area pages untouched"

  # A served page with no card fails as MISSING-CARD.
  mkdir -p "$root/orphan" && printf '<html></html>\n' >"$root/orphan/index.html"
  out=$(python3 "$check" "$root" 2>&1); rc=$?
  expect_code 1 "$rc" "$tag: uncarded page"
  assert_contains "$out" "MISSING-CARD: /orphan/" "$tag: names the uncarded top-level page"
  assert_contains "$out" "UNREACHABLE: /orphan/index.html" "$tag: names the unreachable page"
  rm -r "$root/orphan"

  # A nested page nothing links to fails as UNREACHABLE.
  printf '<html></html>\n' >"$root/casting/old.html"
  out=$(python3 "$check" "$root" 2>&1); rc=$?
  expect_code 1 "$rc" "$tag: unlinked nested page"
  assert_contains "$out" "UNREACHABLE: /casting/old.html" "$tag: names the unlinked nested page"
  printf '<html><body>owner content <a href="/">home</a> <a href="old.html">old</a></body></html>\n' >"$root/casting/index.html"
  out=$(python3 "$check" "$root" 2>&1) || fail "$tag: linked nested page should pass: $out"
  pass "$tag: check fails on uncarded and unreachable pages"

  # A spec item added without a rebuild fails as SPEC-ITEM; a dead link fails as DEAD-CARD.
  cp "$root/index.html" "$TMP_ROOT/$tag-index.bak"
  cp "$root/board.json" "$TMP_ROOT/$tag-spec.bak"
  python3 - "$root/board.json" "$root/index.html" <<'PY2'
import json, sys
spec = json.load(open(sys.argv[1], encoding="utf-8"))
spec["areas"].append({"slug": "publish", "name": "Publishing", "detail": "outlets"})
json.dump(spec, open(sys.argv[1], "w", encoding="utf-8"))
s = open(sys.argv[2], encoding="utf-8").read().replace("</main>", '<a href="/gone/">gone</a></main>')
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY2
  out=$(python3 "$check" "$root" 2>&1); rc=$?
  expect_code 1 "$rc" "$tag: missing spec card"
  assert_contains "$out" "SPEC-ITEM: area 'publish' has no card" "$tag: names the missing spec item"
  assert_contains "$out" "DEAD-CARD: /gone/" "$tag: names the dead card"
  cp "$TMP_ROOT/$tag-index.bak" "$root/index.html"
  cp "$TMP_ROOT/$tag-spec.bak" "$root/board.json"
  pass "$tag: check fails on missing spec items and dead cards"

  # A recorded page that disappears fails as REMOVED.
  python3 "$check" "$root" --record >/dev/null 2>&1 || fail "$tag: record before removal"
  printf '<html><body>owner content <a href="/">home</a></body></html>\n' >"$root/casting/index.html"
  rm "$root/casting/old.html"
  out=$(python3 "$check" "$root" 2>&1); rc=$?
  expect_code 1 "$rc" "$tag: removed page"
  assert_contains "$out" "REMOVED: /casting/old.html" "$tag: names the removed page"
  pass "$tag: check fails when a recorded page is removed"

  # Spec validation: a multi-line detail and a duplicate slug are rejected.
  local bad="$TMP_ROOT/$tag/bad"
  mkdir -p "$bad"
  write_spec "$bad" '{"title":"B","areas":[{"slug":"a","name":"A","detail":"line one\nline two"}]}'
  out=$(python3 "$scaffold" build "$bad" 2>&1); rc=$?
  expect_code 2 "$rc" "$tag: multi-line detail"
  assert_contains "$out" "must be one line" "$tag: explains the one-line rule"
  write_spec "$bad" '{"title":"B","areas":[{"slug":"a","name":"A","detail":"x"},{"slug":"a","name":"A2","detail":"y"}]}'
  out=$(python3 "$scaffold" build "$bad" 2>&1); rc=$?
  expect_code 2 "$rc" "$tag: duplicate slug"
  assert_absent "$bad/index.html" "$tag: invalid spec writes no index"
  pass "$tag: build rejects invalid specs"
}

serve_suite() {  # <skill-dir> <tag>
  local skill=$1 tag=$2 root port pid code headers i
  command -v curl >/dev/null || { pass "$tag: SKIP serve (curl absent)"; return; }
  root="$TMP_ROOT/$tag/serve"
  mkdir -p "$root"
  python3 -c 'import sys; sys.stdout.buffer.write(bytes(range(256)) * 4)' >"$root/clip.bin"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  python3 "$skill/scripts/board_serve.py" "$port" 127.0.0.1 "$root" >/dev/null 2>&1 &
  pid=$!
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/clip.bin" && break
    [ "$i" -lt 50 ] || { kill "$pid" 2>/dev/null; fail "$tag: server did not start"; }
    sleep 0.1
  done
  headers=$(curl -s -D - -o "$TMP_ROOT/$tag-range.out" -H 'Range: bytes=10-19' "http://127.0.0.1:$port/clip.bin")
  assert_contains "$headers" "206" "$tag: range request answers 206"
  assert_contains "$headers" "Content-Range: bytes 10-19/1024" "$tag: Content-Range header"
  assert_equals 10 "$(wc -c <"$TMP_ROOT/$tag-range.out" | tr -d ' ')" "$tag: body is the requested slice"
  code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=-24' "http://127.0.0.1:$port/clip.bin")
  assert_equals 206 "$code" "$tag: suffix range answers 206"
  code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=5000-' "http://127.0.0.1:$port/clip.bin")
  assert_equals 416 "$code" "$tag: unsatisfiable range answers 416"
  headers=$(curl -s -D - -o /dev/null "http://127.0.0.1:$port/clip.bin")
  assert_contains "$headers" "Accept-Ranges: bytes" "$tag: full response advertises ranges"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  pass "$tag: server answers byte ranges"
}

template_suite() {  # <skill-dir> <tag>
  local skill=$1 tag=$2 out
  out=$(grep -c '@[A-Z0-9_]*@' "$skill/templates/board.systemd.service") || fail "$tag: systemd template has no placeholders"
  if command -v plutil >/dev/null; then
    sed 's/@[A-Z0-9_]*@/x/g' "$skill/templates/board.launchd.plist" >"$TMP_ROOT/$tag.plist"
    plutil -lint "$TMP_ROOT/$tag.plist" >/dev/null || fail "$tag: filled launchd template is not a valid plist"
    pass "$tag: launchd template lints once filled"
  else
    pass "$tag: SKIP plist lint (plutil absent)"
  fi
}

for pair in ".agents/skills/captain-boards:internal" "skills/captain-boards:public"; do
  dir=$ROOT/${pair%%:*}
  tag=${pair##*:}
  run_suite "$dir" "$tag"
  serve_suite "$dir" "$tag"
  template_suite "$dir" "$tag"
done
