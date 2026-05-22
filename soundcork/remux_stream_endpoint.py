#!/usr/bin/env python3
"""Small HTTP endpoint that remuxes Ogg-FLAC streams to native FLAC."""

from __future__ import annotations

import argparse
import atexit
import collections
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import NoReturn


DEFAULT_UPSTREAM = "https://amp.cesnet.cz:8443/cro3.flac"
DEFAULT_ALLOWED_HOSTS = ("amp.cesnet.cz", "radio.cesnet.cz")
USER_AGENT = "SoundTouchRemuxProbe/0.1"
STREAM_CHUNK_SIZE = 8 * 1024


class RemuxServer(ThreadingHTTPServer):
    default_upstream: str
    ffmpeg_bin: str
    allowed_hosts: set[str]
    allow_any_upstream: bool
    stop_timeout: float
    max_active_processes: int
    active_lock: threading.Lock
    active_processes: dict[int, tuple[subprocess.Popen[bytes], str]]
    pending_process_slots: int
    total_requests: int
    completed_requests: int
    rejected_requests: int
    client_disconnects: int
    ffmpeg_start_failures: int
    total_bytes_sent: int

    def try_reserve_process_slot(self) -> bool:
        with self.active_lock:
            active_and_pending = len(self.active_processes) + self.pending_process_slots
            if self.max_active_processes > 0 and active_and_pending >= self.max_active_processes:
                self.rejected_requests += 1
                return False
            self.pending_process_slots += 1
            return True

    def register_process(self, proc: subprocess.Popen[bytes], upstream_id: str) -> None:
        with self.active_lock:
            self.pending_process_slots = max(self.pending_process_slots - 1, 0)
            self.active_processes[proc.pid] = (proc, upstream_id)

    def release_process_slot(self) -> None:
        with self.active_lock:
            self.pending_process_slots = max(self.pending_process_slots - 1, 0)

    def unregister_process(self, proc: subprocess.Popen[bytes]) -> None:
        with self.active_lock:
            self.active_processes.pop(proc.pid, None)

    def terminate_process(self, proc: subprocess.Popen[bytes]) -> None:
        if proc.poll() is not None:
            return
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=self.stop_timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=self.stop_timeout)

    def terminate_all(self) -> None:
        with self.active_lock:
            processes = [proc for proc, _upstream_id in self.active_processes.values()]
        for proc in processes:
            self.terminate_process(proc)

    def record_request_started(self) -> None:
        with self.active_lock:
            self.total_requests += 1

    def record_request_rejected(self) -> None:
        with self.active_lock:
            self.rejected_requests += 1

    def record_request_finished(self, bytes_sent: int, client_disconnected: bool) -> None:
        with self.active_lock:
            self.completed_requests += 1
            self.total_bytes_sent += bytes_sent
            if client_disconnected:
                self.client_disconnects += 1

    def record_ffmpeg_start_failure(self) -> None:
        with self.active_lock:
            self.ffmpeg_start_failures += 1

    def metrics_text(self) -> str:
        with self.active_lock:
            active_by_upstream = collections.Counter(
                upstream_id for _proc, upstream_id in self.active_processes.values()
            )
            lines = [
                f"active_processes {len(self.active_processes)}",
                f"total_requests {self.total_requests}",
                f"completed_requests {self.completed_requests}",
                f"rejected_requests {self.rejected_requests}",
                f"client_disconnects {self.client_disconnects}",
                f"ffmpeg_start_failures {self.ffmpeg_start_failures}",
                f"total_bytes_sent {self.total_bytes_sent}",
            ]
        for upstream_id, count in sorted(active_by_upstream.items()):
            lines.append(f'active_processes_by_upstream{{upstream="{_escape_label(upstream_id)}"}} {count}')
        return "\n".join(lines) + "\n"


class RemuxHandler(BaseHTTPRequestHandler):
    server_version = "SoundTouchRemuxProbe/0.1"

    def do_HEAD(self) -> None:
        if self.path_only in {"/flac", "/remux/flac"}:
            self._send_stream_headers()
            return
        if self.path_only == "/healthz":
            self._send_text(200, "ok\n")
            return
        self.send_error(404, "unknown endpoint")

    def do_GET(self) -> None:
        if self.path_only == "/healthz":
            self._send_text(200, "ok\n")
            return
        if self.path_only == "/metrics":
            self._send_text(200, self.server.metrics_text())
            return
        if self.path_only not in {"/flac", "/remux/flac"}:
            self.send_error(404, "unknown endpoint")
            return

        self.server.record_request_started()
        upstream = self._upstream_from_request()
        if upstream is None:
            return
        self._stream_flac(upstream)

    @property
    def path_only(self) -> str:
        return urllib.parse.urlsplit(self.path).path

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write(
            "%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args)
        )

    def _upstream_from_request(self) -> str | None:
        parsed = urllib.parse.urlsplit(self.path)
        params = urllib.parse.parse_qs(parsed.query, keep_blank_values=False)
        upstream = params.get("url", [self.server.default_upstream])[0]
        parsed_upstream = urllib.parse.urlsplit(upstream)
        if parsed_upstream.scheme not in {"http", "https"} or not parsed_upstream.netloc:
            self.server.record_request_rejected()
            self.send_error(400, "upstream URL must be absolute http(s)")
            return None

        host = (parsed_upstream.hostname or "").lower()
        if not self.server.allow_any_upstream and host not in self.server.allowed_hosts:
            self.server.record_request_rejected()
            self.send_error(403, "upstream host is not allowed")
            return None
        return upstream

    def _send_text(self, status_code: int, body: str) -> None:
        payload = body.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-cache, no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _send_stream_headers(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "audio/flac")
        self.send_header("Cache-Control", "no-cache, no-store")
        self.send_header("Connection", "close")
        self.send_header("icy-name", "FLAC remux")
        self.send_header("icy-genre", "classical")
        self.end_headers()

    def _stream_flac(self, upstream: str) -> None:
        upstream_id = _upstream_id(upstream)
        if not self.server.try_reserve_process_slot():
            self.send_error(503, "too many active ffmpeg processes")
            return

        cmd = [
            self.server.ffmpeg_bin,
            "-hide_banner",
            "-nostdin",
            "-nostats",
            "-loglevel",
            "error",
            "-user_agent",
            USER_AGENT,
            "-i",
            upstream,
            "-map",
            "0:a:0",
            "-c:a",
            "copy",
            "-f",
            "flac",
            "pipe:1",
        ]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError as exc:
            self.server.release_process_slot()
            self.server.record_ffmpeg_start_failure()
            if isinstance(exc, FileNotFoundError):
                self.send_error(500, "ffmpeg not found")
            else:
                self.send_error(500, "ffmpeg failed to start")
            return

        assert proc.stdout is not None
        self.server.register_process(proc, upstream_id)
        started = time.monotonic()
        bytes_sent = 0
        client_disconnected = False
        try:
            self._send_stream_headers()
            while True:
                chunk = proc.stdout.read(STREAM_CHUNK_SIZE)
                if not chunk:
                    break
                self.wfile.write(chunk)
                bytes_sent += len(chunk)
        except ConnectionError:
            client_disconnected = True
        finally:
            self.server.terminate_process(proc)
            self.server.unregister_process(proc)
            self.server.record_request_finished(bytes_sent, client_disconnected)
            elapsed = max(time.monotonic() - started, 0.001)
            self.log_message(
                "remux finished upstream=%s bytes=%d elapsed=%.3fs kbit_s=%.1f",
                upstream,
                bytes_sent,
                elapsed,
                bytes_sent * 8 / elapsed / 1000,
            )


def _upstream_id(upstream: str) -> str:
    parsed = urllib.parse.urlsplit(upstream)
    host = (parsed.hostname or "").lower()
    if parsed.port is not None:
        host = f"{host}:{parsed.port}"
    path = parsed.path or "/"
    return f"{host}{path}"


def _escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8768)
    parser.add_argument("--default-upstream", default=DEFAULT_UPSTREAM)
    parser.add_argument("--allow-host", action="append", default=list(DEFAULT_ALLOWED_HOSTS))
    parser.add_argument("--allow-any-upstream", action="store_true")
    parser.add_argument("--ffmpeg-stop-timeout", type=float, default=3.0)
    parser.add_argument("--ffmpeg-bin", default="ffmpeg")
    parser.add_argument("--max-active-processes", type=int, default=0)
    return parser.parse_args()


def main() -> NoReturn:
    args = parse_args()
    server = RemuxServer((args.host, args.port), RemuxHandler)
    server.default_upstream = args.default_upstream
    server.allowed_hosts = {host.lower() for host in args.allow_host}
    server.allow_any_upstream = args.allow_any_upstream
    server.stop_timeout = args.ffmpeg_stop_timeout
    server.ffmpeg_bin = args.ffmpeg_bin
    server.max_active_processes = max(args.max_active_processes, 0)
    server.active_lock = threading.Lock()
    server.active_processes = {}
    server.pending_process_slots = 0
    server.total_requests = 0
    server.completed_requests = 0
    server.rejected_requests = 0
    server.client_disconnects = 0
    server.ffmpeg_start_failures = 0
    server.total_bytes_sent = 0

    def shutdown(signum: int | None = None, _frame: object | None = None) -> NoReturn:
        if signum is not None:
            print(f"received signal {signum}, shutting down", file=sys.stderr, flush=True)
        server.terminate_all()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    atexit.register(server.terminate_all)

    print(f"listening on http://{args.host}:{args.port}", flush=True)
    print(f"default upstream: {args.default_upstream}", flush=True)
    if args.allow_any_upstream:
        print("allowed upstream hosts: any", flush=True)
    else:
        print("allowed upstream hosts: " + ", ".join(sorted(server.allowed_hosts)), flush=True)

    try:
        server.serve_forever()
    finally:
        server.terminate_all()


if __name__ == "__main__":
    main()
