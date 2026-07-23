#!/usr/bin/env python3
"""range-server.py — stdlib-only HTTP test harness for Goel's URLSessionTransferEngine (T05).

Python's http.server.SimpleHTTPRequestHandler does NOT implement Range requests — it
silently hands back the whole file, which makes a broken segmented downloader look like it
works. This server is honest about ranges instead.

Usage:
    python3 Scripts/ios/range-server.py [--port 8099] [--dir Scripts/ios/fixtures]
                                         [--no-ranges] [--throttle BYTES_PER_SEC] [--flap N]

Endpoints: whatever files exist under --dir, served by relative path.
"""
from __future__ import annotations

import argparse
import email.utils
import http.server
import itertools
import mimetypes
import os
import socket
import struct
import sys
import threading
import time
from pathlib import Path
from urllib.parse import unquote, urlsplit

DEFAULT_PORT = 8099
CHUNK_MAX = 64 * 1024


def make_etag(stat: os.stat_result) -> str:
    """Strong ETag derived from size + mtime (nanosecond resolution) — changes iff the
    file's content plausibly changed, stable across repeated stats of an untouched file."""
    return f'"{stat.st_size:x}-{stat.st_mtime_ns:x}"'


def guess_content_type(path: Path) -> str:
    if path.suffix == ".sha256":
        return "text/plain; charset=utf-8"
    ctype, _ = mimetypes.guess_type(str(path))
    return ctype or "application/octet-stream"


def parse_range(range_header, file_size):
    """Parse a single `Range: bytes=...` header.

    Returns (start, end) inclusive, the string 'unsatisfiable', or the string 'invalid'
    (malformed syntax — caller should treat this the same as "no Range header": RFC 9110
    says a server MAY ignore a syntactically invalid Range and serve the full 200).
    """
    if file_size <= 0:
        return "unsatisfiable"
    if not range_header or not range_header.startswith("bytes="):
        return "invalid"
    spec = range_header[len("bytes="):].strip()
    if "," in spec:
        # Multi-range requests aren't needed for this harness; honor the first range only.
        spec = spec.split(",", 1)[0].strip()
    if "-" not in spec:
        return "invalid"
    start_str, _, end_str = spec.partition("-")
    if start_str == "" and end_str == "":
        return "invalid"
    if start_str == "":
        # Suffix form: bytes=-N -> last N bytes of the file.
        try:
            suffix_len = int(end_str)
        except ValueError:
            return "invalid"
        if suffix_len <= 0:
            return "unsatisfiable"
        start = max(0, file_size - suffix_len)
        end = file_size - 1
        return (start, end)
    try:
        start = int(start_str)
    except ValueError:
        return "invalid"
    if start >= file_size:
        return "unsatisfiable"
    if end_str == "":
        end = file_size - 1
    else:
        try:
            end = int(end_str)
        except ValueError:
            return "invalid"
        if end < start:
            return "invalid"
        if end >= file_size:
            end = file_size - 1
    return (start, end)


class RangeHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address, handler_cls, *, directory, no_ranges, throttle, flap):
        self.directory = directory
        self.no_ranges = no_ranges
        self.throttle = throttle
        self.flap = flap
        self._request_counter = itertools.count(1)
        self._counter_lock = threading.Lock()
        super().__init__(server_address, handler_cls)

    def next_request_id(self) -> int:
        with self._counter_lock:
            return next(self._request_counter)

    def handle_error(self, request, client_address):
        # A client cancelling a segment mid-flight (or our own --flap abort) surfaces here
        # as some flavor of OSError once we're outside the request handler's own try/except
        # (e.g. the stdlib's post-handler wfile.flush()). Don't spam a traceback for that.
        exc = sys.exc_info()[1]
        if isinstance(exc, OSError):
            return
        super().handle_error(request, client_address)


class RangeRequestHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "RangeServer/1.0"

    # ---- plumbing ----------------------------------------------------

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        pass  # we log ourselves, concisely, in _log()

    def _log(self, method, path, range_desc, status, bytes_sent):
        sys.stderr.write(
            f"{method} {path} range={range_desc or '-'} status={status} bytes={bytes_sent}\n"
        )
        sys.stderr.flush()

    def _resolve_path(self):
        url_path = unquote(urlsplit(self.path).path)
        rel = os.path.normpath(url_path).lstrip("/")
        if rel in ("", "."):
            return None
        base = Path(self.server.directory).resolve()
        candidate = (base / rel).resolve()
        if candidate != base and base not in candidate.parents:
            return None  # path traversal attempt
        if not candidate.is_file():
            return None
        return candidate

    @staticmethod
    def _etag_list_matches(header_value, etag):
        if header_value is None:
            return False
        if header_value.strip() == "*":
            return True
        return etag in (c.strip() for c in header_value.split(","))

    # ---- request handlers ---------------------------------------------

    def do_HEAD(self):
        self._serve(send_body=False)

    def do_GET(self):
        self._serve(send_body=True)

    def _serve(self, send_body):
        self.close_connection = True  # one request per connection: keeps throttle/flap simple
        # Only GETs consume the flap counter — HEAD is used for probing and shouldn't flap.
        request_id = self.server.next_request_id() if send_body else 0

        path = self._resolve_path()
        if path is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self._log(self.command, self.path, None, 404, 0)
            return

        try:
            stat = path.stat()
        except OSError:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self._log(self.command, self.path, None, 404, 0)
            return

        size = stat.st_size
        etag = make_etag(stat)
        last_modified = email.utils.formatdate(stat.st_mtime, usegmt=True)
        ctype = guess_content_type(path)
        no_ranges = self.server.no_ranges

        if_match = self.headers.get("If-Match")
        if if_match and not self._etag_list_matches(if_match, etag):
            self.send_response(412)
            self.send_header("ETag", etag)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self._log(self.command, self.path, None, 412, 0)
            return

        if_none_match = self.headers.get("If-None-Match")
        if if_none_match and self._etag_list_matches(if_none_match, etag):
            self.send_response(304)
            self.send_header("ETag", etag)
            self.send_header("Last-Modified", last_modified)
            self.end_headers()
            self._log(self.command, self.path, None, 304, 0)
            return

        range_header = None
        range_result = None
        if send_body:
            range_header = None if no_ranges else self.headers.get("Range")
            if_range = self.headers.get("If-Range")
            if range_header and if_range:
                # RFC 9110 §13.1.5: only honor Range when the validator still matches;
                # otherwise ignore Range entirely and fall through to a full 200.
                if if_range.strip() not in (etag, last_modified):
                    range_header = None
            range_result = parse_range(range_header, size) if range_header else None

        if range_result == "unsatisfiable":
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Type", ctype)
            if not no_ranges:
                self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", "0")
            self.end_headers()
            self._log(self.command, self.path, range_header, 416, 0)
            return

        if range_result and range_result != "invalid":
            start, end = range_result
            length = end - start + 1
            status = 206
        else:
            start, end = 0, size - 1
            length = size
            status = 200

        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Last-Modified", last_modified)
        self.send_header("ETag", etag)
        if not no_ranges:
            self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Connection", "close")
        self.end_headers()

        bytes_sent = 0
        if send_body and length > 0:
            bytes_sent = self._send_body(path, start, length, request_id)

        self._log(self.command, self.path, range_header, status, bytes_sent)

    # ---- body streaming -------------------------------------------------

    def _send_body(self, path, start, length, request_id):
        throttle = self.server.throttle
        flap_limit = self.server.flap
        flap_this = flap_limit is not None and request_id % 5 == 0

        chunk_size = CHUNK_MAX
        if throttle:
            chunk_size = max(1, min(CHUNK_MAX, throttle // 10 or 1))

        sent = 0
        t_start = time.monotonic()
        try:
            with open(path, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    data = f.read(min(chunk_size, remaining))
                    if not data:
                        break
                    self.wfile.write(data)
                    sent += len(data)
                    remaining -= len(data)

                    if flap_this and sent >= flap_limit:
                        self._abort_connection()
                        return sent

                    if throttle:
                        target = t_start + sent / throttle
                        now = time.monotonic()
                        if target > now:
                            time.sleep(target - now)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client cancelled the segment mid-flight; that's routine, not an error
        return sent

    def _abort_connection(self):
        """Simulate a dropped connection for --flap: RST instead of a graceful FIN."""
        try:
            self.connection.setsockopt(
                socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
            )
        except OSError:
            pass
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.close_connection = True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--dir", type=str, default=None, help="directory to serve (default: fixtures/ next to this script)")
    parser.add_argument("--no-ranges", action="store_true", help="omit Accept-Ranges and ignore every Range header")
    parser.add_argument("--throttle", type=int, default=None, metavar="BYTES_PER_SEC", help="pace responses per-connection")
    parser.add_argument("--flap", type=int, default=None, metavar="N", help="abruptly close after N bytes on every 5th GET")
    args = parser.parse_args()

    directory = Path(args.dir).resolve() if args.dir else (Path(__file__).resolve().parent / "fixtures")
    if not directory.is_dir():
        print(f"range-server: directory not found: {directory}", file=sys.stderr)
        sys.exit(1)

    throttle = args.throttle if args.throttle and args.throttle > 0 else None

    server = RangeHTTPServer(
        ("0.0.0.0", args.port),
        RangeRequestHandler,
        directory=str(directory),
        no_ranges=args.no_ranges,
        throttle=throttle,
        flap=args.flap,
    )
    print(
        f"range-server: serving {directory} on :{args.port} "
        f"(ranges={'off' if args.no_ranges else 'on'}, throttle={throttle or 'none'}, flap={args.flap or 'none'})",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
