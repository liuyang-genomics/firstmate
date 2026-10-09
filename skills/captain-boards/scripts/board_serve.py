#!/usr/bin/env python3
"""board_serve.py - static file server with HTTP Range support for a board.

Usage:
  board_serve.py PORT BIND ROOT

Safari plays and seeks <audio>/<video> only when the server answers byte ranges with
206 Partial Content; `python3 -m http.server` answers 200 to everything. This server
handles one range per request (bytes=a-b, bytes=a-, bytes=-n), answers 416 for an
unsatisfiable range, sends Accept-Ranges on every file, and serves with threads.
Run it under the launchd or systemd template in this skill.
"""
import os
import re
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class RangeHandler(SimpleHTTPRequestHandler):
    def send_head(self):
        self._left = None
        rng = self.headers.get("Range")
        path = self.translate_path(self.path)
        if not rng or not os.path.isfile(path):
            return super().send_head()
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip())
        if not m or not (m.group(1) or m.group(2)):
            return super().send_head()
        size = os.path.getsize(path)
        first, last = m.groups()
        if first:
            start, end = int(first), int(last) if last else size - 1
        else:
            start, end = max(size - int(last), 0), size - 1
        end = min(end, size - 1)
        if start > end or start >= size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        f = open(path, "rb")
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self._left = end - start + 1
        return f

    def copyfile(self, source, outputfile):
        left = getattr(self, "_left", None)
        if left is None:
            return super().copyfile(source, outputfile)
        while left > 0:
            buf = source.read(min(65536, left))
            if not buf:
                break
            outputfile.write(buf)
            left -= len(buf)

    def end_headers(self):
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()


def main():
    if len(sys.argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    port, bind, root = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    if not os.path.isdir(root):
        print(f"board_serve: {root} is not a directory", file=sys.stderr)
        return 2
    ThreadingHTTPServer((bind, port), partial(RangeHandler, directory=root)).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
