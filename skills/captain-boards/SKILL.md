---
name: captain-boards
description: Page contract and tooling for status boards, small LAN-served static sites where each area of a project keeps one stable page with its whole current picture for the person you report to. Use when creating, updating, serving, or retiring board pages, or when posting an update, a pending decision, or a choice between candidates to a board instead of chat.
---

# captain-boards

A board is a small static site, served on the local network, where each area of work keeps one stable page with its complete current picture.
Chat carries only a link and one line; the board carries the substance.
Run the completeness check before every publish.

## Page contract

Check every item before you publish a board change.

- [ ] **One stable whole-picture page per area.** Each area of the project owns exactly one persistent page that shows its complete current picture.
- [ ] **Updated in place, never repurposed.** A page keeps its URL and its subject; new subject matter gets a new area page.
- [ ] **Index completeness.** Every page served by the board's host has a card on the root index, and every deeper page is reachable by links from it; a page without a card is a defect.
- [ ] **Naming.** Each card shows a short name, bilingual when the reader uses two languages (`Name / 名字`), plus a one-line detail of what the page holds.
- [ ] **Nothing removed, only moved.** A superseded page becomes a redirect or an archived copy that stays reachable from the index; a retired area keeps its card marked retired with where it moved.
- [ ] **Updates go on the board.** Results, items to review, and pending approvals are posted on the area's page; the chat message is the page link plus one line.
- [ ] **Waiting on you at the top.** The index and every area page open with a "Waiting on you" box listing what needs the reader, or saying nothing does.
- [ ] **Pick cards.** When the reader must choose (a voice, a take, a design), each candidate is a card with a player or preview of a casual-speech sample, not a formal or cherry-picked reading, so candidates are compared on equal footing.
- [ ] **Area scope stays put.** An area page holds only its own picture; a different update goes on its own area page.
- [ ] **Playable media.** The board is served with HTTP Range support so audio and video play and seek in every browser, Safari included.
- [ ] **Private content stays on the board host.** Board content lives in the board's own served directory, never in a tracked repository.

## Tools

All scripts are Python 3 standard library and print their own usage with `--help` (the server prints usage when run without arguments).
Their headers own the exact formats.

- `scripts/board_scaffold.py init ROOT --title TITLE` creates `ROOT/board.json`, the single source of the index, then builds.
  `scripts/board_scaffold.py build ROOT` regenerates `ROOT/index.html` from it: Waiting-on-you box first, newest updates next, then one card per area and extra link.
  It writes a stub page only for an area whose page does not exist yet, never touches an existing area page, and never deletes anything.
- `scripts/board_check.py ROOT` fails on any page or spec item missing from the index, any dead card, and any recorded page that disappeared; `--record` after a clean pass adds the current pages to the `ROOT/board-pages.txt` ledger that the removal check reads.
- `scripts/board_serve.py PORT BIND ROOT` serves the board with single-range HTTP Range support.
- `templates/board.launchd.plist` (macOS) and `templates/board.systemd.service` (Linux) keep the server running; fill their `@PLACEHOLDERS@` and follow the install lines in each template's header.

## Publish cycle

1. Edit the area page in place, and edit `board.json` for any new area, card, waiting item, or update line.
2. Run `board_scaffold.py build ROOT`.
3. Run `board_check.py ROOT --record`; fix every defect it prints before announcing the change.
4. Send the reader the page link plus one line.
