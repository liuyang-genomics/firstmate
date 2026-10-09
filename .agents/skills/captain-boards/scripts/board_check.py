#!/usr/bin/env python3
"""board_check.py - fail when any served page or spec item is missing from a captain board's index.

Usage:
  board_check.py ROOT [--record]

ROOT is the directory the board server serves. Exit 0 when complete, 1 with one line
per defect, 2 on usage errors. Defects:
  MISSING-CARD  a top-level entry of ROOT has no link from ROOT/index.html
  UNREACHABLE   an .html page cannot be reached by following local links from ROOT/index.html
  DEAD-CARD     a local link on ROOT/index.html points at nothing
  SPEC-ITEM     a board.json area or link has no card on ROOT/index.html
  REMOVED       a page recorded in ROOT/board-pages.txt no longer exists (move it, never remove it)

--record (only after a clean pass) adds every current page to ROOT/board-pages.txt, the
ledger REMOVED is checked against. Top-level entries exempt from MISSING-CARD: index.html,
board.json, board-pages.txt, dotfiles, and the paths listed in board.json "assets".
"""
import argparse
import json
import os
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

LEDGER = "board-pages.txt"
SPEC = "board.json"


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            for k, v in attrs:
                if k == "href" and v:
                    self.hrefs.append(v)


def hrefs_of(path):
    p = Links()
    p.feed(path.read_text(encoding="utf-8", errors="replace"))
    return p.hrefs


def resolve(root, page, href):
    """Local filesystem target of href on page, or None for external/fragment-only links."""
    parts = urlsplit(href)
    if parts.scheme or parts.netloc or not parts.path:
        return None
    rel = unquote(parts.path)
    base = root if rel.startswith("/") else page.parent
    # Lexical, like the server: a symlinked area directory is served under its link name.
    return Path(os.path.normpath(base / rel.lstrip("/")))


def inside(root, path):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def crawl(root, start):
    seen, queue = set(), [start]
    while queue:
        node = queue.pop()
        if node in seen or not inside(root, node) or not node.exists():
            continue
        seen.add(node)
        if node.is_dir():
            idx = node / "index.html"
            # A directory without index.html is served as a listing of its children.
            queue.extend([idx] if idx.is_file() else list(node.iterdir()))
        elif node.suffix.lower() in (".html", ".htm"):
            for h in hrefs_of(node):
                t = resolve(root, node, h)
                if t is not None:
                    queue.append(t)
    return seen


def served_pages(root):
    """Every .html page the server would serve, following symlinked directories once."""
    seen_dirs = set()
    for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
        real = os.path.realpath(dirpath)
        if real in seen_dirs:
            dirnames[:] = []
            continue
        seen_dirs.add(real)
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for f in filenames:
            if not f.startswith(".") and f.lower().endswith((".html", ".htm")):
                yield Path(dirpath) / f


def main():
    ap = argparse.ArgumentParser(description="Check that a captain board's index covers every page.")
    ap.add_argument("root")
    ap.add_argument("--record", action="store_true", help="after a clean pass, add current pages to the ledger")
    args = ap.parse_args()
    root = Path(os.path.abspath(args.root))
    index = root / "index.html"
    if not index.is_file():
        print(f"board_check: {index} not found", file=sys.stderr)
        return 2

    spec = {}
    if (root / SPEC).is_file():
        try:
            spec = json.loads((root / SPEC).read_text(encoding="utf-8"))
        except ValueError as err:
            print(f"board_check: {root / SPEC}: invalid JSON: {err}", file=sys.stderr)
            return 2
    exempt = {"index.html", SPEC, LEDGER} | {a.strip("/") for a in spec.get("assets", [])}

    defects = []
    targets = []
    for h in hrefs_of(index):
        t = resolve(root, index, h)
        if t is None:
            continue
        if not inside(root, t) or not t.exists():
            defects.append(f"DEAD-CARD: {h}")
            continue
        targets.append(t)

    def carded(path):
        return any(t == path or inside(path, t) for t in targets)

    for entry in sorted(root.iterdir()):
        if entry.name.startswith(".") or entry.name in exempt:
            continue
        if not carded(entry):
            defects.append(f"MISSING-CARD: /{entry.name}{'/' if entry.is_dir() else ''}")

    for a in spec.get("areas", []):
        if not any(t == root / a["slug"] or inside(root / a["slug"], t) for t in targets):
            defects.append(f"SPEC-ITEM: area '{a['slug']}' has no card")
    for ln in spec.get("links", []):
        if root / ln["path"].lstrip("/") not in targets:
            defects.append(f"SPEC-ITEM: link '{ln['path']}' has no card")

    reached = crawl(root, index)
    pages = sorted(served_pages(root))
    for p in pages:
        if p not in reached:
            defects.append(f"UNREACHABLE: /{p.relative_to(root).as_posix()}")

    ledger_path = root / LEDGER
    ledger = set()
    if ledger_path.is_file():
        ledger = {ln.strip() for ln in ledger_path.read_text(encoding="utf-8").splitlines() if ln.strip()}
    for rel in sorted(ledger):
        if not (root / rel.lstrip("/")).exists():
            defects.append(f"REMOVED: {rel}")

    if defects:
        print("\n".join(defects))
        print(f"board_check: {len(defects)} defect(s) in {root}", file=sys.stderr)
        return 1
    if args.record:
        current = {"/" + p.relative_to(root).as_posix() for p in pages}
        ledger_path.write_text("\n".join(sorted(ledger | current)) + "\n", encoding="utf-8")
    print(f"ok: {len(pages)} page(s), every page and item indexed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
