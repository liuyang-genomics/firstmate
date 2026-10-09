#!/usr/bin/env python3
"""board_scaffold.py - generate a board static site from its board.json spec.

Usage:
  board_scaffold.py init  ROOT --title TITLE   create ROOT/board.json (if absent) and build
  board_scaffold.py build ROOT                 regenerate ROOT/index.html from ROOT/board.json

board.json (the single source of the index):
  {
    "title": "Board",
    "waiting": [{"text": "one line", "link": "/area/#item"}],
    "updates": [{"date": "YYYY-MM-DD", "text": "one line", "link": "/area/"}],
    "areas": [
      {"slug": "casting", "name": "Voice Pick", "alt": "second-language name",
       "detail": "one line", "retired": false, "moved_to": "/other/"}
    ],
    "links": [{"path": "READ-THIS.txt", "name": "Read This", "alt": "", "detail": "one line"}],
    "assets": ["static/"]
  }

build regenerates only ROOT/index.html. For an area whose page is missing it writes
a stub ROOT/<slug>/index.html once; an existing area page is never touched, since the
area owner updates it in place. Nothing is ever deleted. Spec errors exit 2.
"""
import argparse
import html
import json
import sys
from pathlib import Path

NAME_MAX = 40
DETAIL_MAX = 140

CSS = (
    ":root{--bg:#f6f4ef;--card:#fff;--ink:#1d1d1b;--mute:#6b6a64;--line:#dedbd2;--accent:#1f6f5c;--warn:#b4531a}"
    "@media (prefers-color-scheme:dark){:root{--bg:#16171a;--card:#202226;--ink:#ececea;--mute:#a1a09a;"
    "--line:#34363b;--accent:#4db39b;--warn:#e08a4a}}"
    "body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,system-ui,sans-serif}"
    "main{max-width:980px;margin:0 auto;padding:16px}a{color:var(--accent)}h1{font-size:21px;margin:6px 0}"
    "h2{font-size:17px;margin:20px 0 6px}nav{margin:6px 0 12px;font-size:14px;overflow-wrap:anywhere}"
    ".u{background:var(--card);border:1px solid var(--line);border-left:3px solid var(--accent);"
    "border-radius:8px;padding:8px 12px;margin:8px 0;font-size:14px}.u.w{border-left-color:var(--warn)}"
    ".d{color:var(--mute);font-size:12px}audio{width:100%;margin-top:6px}"
)


def die(msg, code=2):
    print(f"board_scaffold: {msg}", file=sys.stderr)
    sys.exit(code)


def e(s):
    return html.escape(str(s), quote=True)


def one_line(where, field, value, limit, required=True):
    if value is None or value == "":
        if required:
            die(f"{where}: '{field}' is required")
        return
    if not isinstance(value, str):
        die(f"{where}: '{field}' must be a string")
    if "\n" in value or "\r" in value:
        die(f"{where}: '{field}' must be one line")
    if len(value) > limit:
        die(f"{where}: '{field}' is {len(value)} chars, limit {limit}")


def load_spec(root):
    path = root / "board.json"
    if not path.is_file():
        die(f"{path} not found; run init first")
    try:
        spec = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as err:
        die(f"{path}: invalid JSON: {err}")
    one_line("board.json", "title", spec.get("title"), NAME_MAX)
    seen = set()
    for i, a in enumerate(spec.get("areas", [])):
        where = f"areas[{i}]"
        slug = a.get("slug", "")
        if not slug or "/" in slug or slug.startswith(".") or slug in {"index.html", "board.json"}:
            die(f"{where}: 'slug' must be a single path segment")
        if slug in seen:
            die(f"{where}: duplicate slug '{slug}'")
        seen.add(slug)
        one_line(where, "name", a.get("name"), NAME_MAX)
        one_line(where, "alt", a.get("alt"), NAME_MAX, required=False)
        one_line(where, "detail", a.get("detail"), DETAIL_MAX)
    for i, ln in enumerate(spec.get("links", [])):
        where = f"links[{i}]"
        if not ln.get("path"):
            die(f"{where}: 'path' is required")
        one_line(where, "name", ln.get("name"), NAME_MAX)
        one_line(where, "alt", ln.get("alt"), NAME_MAX, required=False)
        one_line(where, "detail", ln.get("detail"), DETAIL_MAX)
    for key in ("waiting", "updates"):
        for i, it in enumerate(spec.get(key, [])):
            one_line(f"{key}[{i}]", "text", it.get("text"), DETAIL_MAX)
    return spec


def label(item):
    alt = item.get("alt")
    return f"{item['name']} / {alt}" if alt else item["name"]


def page(title, nav, body):
    return (
        '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f"<title>{e(title)}</title><style>{CSS}</style></head><body><main>"
        f"<nav>{nav}</nav><h1>{e(title)}</h1>{body}</main></body></html>\n"
    )


def nav_for(spec):
    parts = [f'<a href="/">{e(spec["title"])}</a>']
    parts += [f'<a href="/{e(a["slug"])}/">{e(a["name"])}</a>' for a in spec.get("areas", []) if not a.get("retired")]
    return " | ".join(parts)


def waiting_box(items):
    if not items:
        return '<div class="u w" id="waiting"><b>Waiting on you</b><div class="d">Nothing waiting on you.</div></div>'
    rows = "".join(
        f'<div>{e(it["text"])}' + (f' - <a href="{e(it["link"])}">open</a>' if it.get("link") else "") + "</div>"
        for it in items
    )
    return f'<div class="u w" id="waiting"><b>Waiting on you</b>{rows}</div>'


def card(href, item, note=""):
    return (
        f'<div class="u"><a href="{e(href)}"><b>{e(label(item))}</b></a>'
        f'<div class="d">{e(item["detail"])}{e(note)}</div></div>'
    )


def build_index(spec):
    body = [waiting_box(spec.get("waiting", []))]
    updates = sorted(spec.get("updates", []), key=lambda u: u.get("date", ""), reverse=True)
    if updates:
        body.append("<h2>Updates</h2>")
        for u in updates:
            link = f' - <a href="{e(u["link"])}">open</a>' if u.get("link") else ""
            body.append(f'<div class="d">{e(u.get("date", ""))} {e(u["text"])}{link}</div>')
    body.append("<h2>Areas</h2>")
    for a in spec.get("areas", []):
        note = ""
        if a.get("retired"):
            note = f" (retired; moved to {a['moved_to']})" if a.get("moved_to") else " (retired)"
        body.append(card(f'/{a["slug"]}/', a, note))
    for ln in spec.get("links", []):
        body.append(card("/" + ln["path"].lstrip("/"), ln))
    return page(spec["title"], nav_for(spec), "".join(body))


def area_stub(spec, area):
    body = (
        waiting_box([])
        + '<div class="u"><b>Current picture</b><div class="d">'
        + e(area["detail"])
        + "</div></div><h2>Updates</h2><div class=\"d\">No updates yet.</div>"
    )
    return page(label(area), nav_for(spec), body)


def build(root):
    spec = load_spec(root)
    for a in spec.get("areas", []):
        target = root / a["slug"] / "index.html"
        if a.get("retired") or target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(area_stub(spec, a), encoding="utf-8")
        print(f"created {target}")
    (root / "index.html").write_text(build_index(spec), encoding="utf-8")
    print(f"wrote {root / 'index.html'}")


def init(root, title):
    one_line("--title", "title", title, NAME_MAX)
    root.mkdir(parents=True, exist_ok=True)
    spec_path = root / "board.json"
    if spec_path.exists():
        print(f"kept existing {spec_path}")
    else:
        spec = {"title": title, "waiting": [], "updates": [], "areas": [], "links": [], "assets": []}
        spec_path.write_text(json.dumps(spec, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"created {spec_path}")
    build(root)


def main():
    ap = argparse.ArgumentParser(description="Generate a board static site from board.json.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p_init = sub.add_parser("init", help="create board.json if absent, then build")
    p_init.add_argument("root")
    p_init.add_argument("--title", required=True)
    p_build = sub.add_parser("build", help="regenerate index.html from board.json")
    p_build.add_argument("root")
    args = ap.parse_args()
    root = Path(args.root)
    if args.cmd == "init":
        init(root, args.title)
    else:
        build(root)


if __name__ == "__main__":
    main()
