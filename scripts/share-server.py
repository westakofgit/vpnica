#!/usr/bin/env python3
import argparse
import signal
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class ShareHTTPServer(HTTPServer):
    downloads = 0


class ShareHandler(BaseHTTPRequestHandler):
    server_version = "vpnica-share"
    sys_version = ""

    def log_message(self, _format, *_args):
        return

    def _matches(self):
        return self.path == self.server.download_path

    def _send_headers(self, include_body):
        if not self._matches() or not self.server.archive.is_file():
            self.send_error(404)
            return False

        size = self.server.archive.stat().st_size
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Disposition", 'attachment; filename="vpnica.zip"')
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        return include_body

    def do_HEAD(self):
        self._send_headers(False)

    def do_GET(self):
        if not self._send_headers(True):
            return

        try:
            with self.server.archive.open("rb") as archive:
                while chunk := archive.read(1024 * 1024):
                    self.wfile.write(chunk)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
            return

        self.server.downloads += 1


def remove_if_current(state_file, token):
    try:
        if f"TOKEN={token}" in state_file.read_text(encoding="utf-8").splitlines():
            state_file.unlink()
    except FileNotFoundError:
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--token", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--ttl", required=True, type=int)
    parser.add_argument("--max-downloads", required=True, type=int)
    parser.add_argument("--state-file", required=True, type=Path)
    args = parser.parse_args()

    server = ShareHTTPServer(("0.0.0.0", args.port), ShareHandler)
    server.archive = args.archive
    server.download_path = f"/d/{args.token}/vpnica.zip"
    server.timeout = 1

    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    deadline = time.monotonic() + args.ttl

    try:
        while (
            not stopping
            and time.monotonic() < deadline
            and server.downloads < args.max_downloads
        ):
            server.handle_request()
    finally:
        server.server_close()
        try:
            args.archive.unlink()
        except FileNotFoundError:
            pass
        remove_if_current(args.state_file, args.token)


if __name__ == "__main__":
    main()
