"""
HTTP layer: JSON API, a Server-Sent Events stream, and the static files.

Built on http.server so the whole backend needs nothing installed beyond
the MetaTrader5 package. ThreadingHTTPServer is right for the workload: a
handful of viewers, one long-lived SSE connection each.

Every route that returns bot state passes through the Redactor first, and
the developer flag comes only from a valid session cookie.

READ ONLY. There is no endpoint that opens, modifies or closes an order.
The dashboard can watch the suite; it cannot touch it.
"""

from __future__ import annotations

import json
import mimetypes
import posixpath
import threading
import time
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from .auth import TOKEN_COOKIE, AuthManager
from .config import Config
from .redact import Redactor

RANGES = {
    "1h": 3600,
    "6h": 6 * 3600,
    "24h": 86400,
    "7d": 7 * 86400,
    "30d": 30 * 86400,
    "all": 0,
}


class Context:
    """Everything the handler needs, passed in rather than made global."""

    def __init__(
        self,
        *,
        cfg: Config,
        auth: AuthManager,
        redactor: Redactor,
        poller,
        store,
        frontend_dir: Path,
    ) -> None:
        self.cfg = cfg
        self.auth = auth
        self.redactor = redactor
        self.poller = poller
        self.store = store
        self.frontend_dir = frontend_dir
        self.started = time.time()


class Handler(BaseHTTPRequestHandler):
    server_version = "KrishMixDash/1.0"
    protocol_version = "HTTP/1.1"
    ctx: Context  # injected by make_server

    # --- plumbing ----------------------------------------------------
    def log_message(self, fmt: str, *args: Any) -> None:  # quieter default
        if self.path.startswith("/api/events"):
            return
        print(f"[http] {self.address_string()} {fmt % args}")

    def _client(self) -> str:
        return self.client_address[0] if self.client_address else "?"

    def _cookie_token(self) -> str | None:
        raw = self.headers.get("Cookie")
        if not raw:
            return None
        try:
            jar = SimpleCookie()
            jar.load(raw)
        except Exception:
            return None
        morsel = jar.get(TOKEN_COOKIE)
        return morsel.value if morsel else None

    def _is_developer(self) -> bool:
        return self.ctx.auth.validate(self._cookie_token()) is not None

    def _send_json(self, obj: Any, status: int = 200, extra_headers: list = ()) -> None:
        body = json.dumps(obj, separators=(",", ":"), default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in extra_headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if n <= 0 or n > 64 * 1024:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8")) or {}
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}

    # --- routing -----------------------------------------------------
    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        route = parsed.path
        query = parse_qs(parsed.query)

        try:
            if route == "/api/session":
                return self._api_session()
            if route == "/api/state":
                return self._api_state()
            if route == "/api/series":
                return self._api_series(query)
            if route == "/api/trades":
                return self._api_trades(query)
            if route == "/api/strategies":
                return self._api_strategies(query)
            if route == "/api/health":
                return self._api_health()
            if route == "/api/events":
                return self._api_events()
            if route.startswith("/api/"):
                return self._send_json({"error": "unknown endpoint"}, 404)
            return self._serve_static(route)
        except (BrokenPipeError, ConnectionResetError):
            pass  # browser navigated away mid-response

    def do_POST(self) -> None:
        route = urlparse(self.path).path
        try:
            if route == "/api/unlock":
                return self._api_unlock()
            if route == "/api/lock":
                return self._api_lock()
            if route == "/api/pin":
                return self._api_change_pin()
            return self._send_json({"error": "unknown endpoint"}, 404)
        except (BrokenPipeError, ConnectionResetError):
            pass

    # --- developer mode ---------------------------------------------
    def _api_session(self) -> None:
        info = self.ctx.auth.session_info(self._cookie_token())
        info["pinConfigured"] = self.ctx.cfg.has_pin
        info["lockedFor"] = self.ctx.auth.lockout_remaining(self._client())
        info["settings"] = self.ctx.cfg.public_dict()
        self._send_json(info)

    def _api_unlock(self) -> None:
        client = self._client()

        wait = self.ctx.auth.lockout_remaining(client)
        if wait > 0:
            return self._send_json(
                {"ok": False, "error": "too many attempts", "retryAfter": wait},
                HTTPStatus.TOO_MANY_REQUESTS,
            )

        pin = str(self._read_json().get("pin", ""))
        if not pin:
            return self._send_json({"ok": False, "error": "pin required"}, 400)

        if not self.ctx.cfg.check_pin(pin):
            lock = self.ctx.auth.record_failure(client)
            payload = {
                "ok": False,
                "error": "incorrect PIN",
                "attemptsLeft": self.ctx.auth.attempts_left(client),
            }
            if lock:
                payload["retryAfter"] = lock
                payload["error"] = "too many attempts"
            return self._send_json(payload, HTTPStatus.UNAUTHORIZED)

        self.ctx.auth.clear_failures(client)
        sess = self.ctx.auth.issue(client)

        # HttpOnly so page scripts cannot read or leak the token; the UI
        # asks /api/session whether it is unlocked instead.
        cookie = (
            f"{TOKEN_COOKIE}={sess.token}; Path=/; HttpOnly; SameSite=Strict; "
            f"Max-Age={int(sess.expires - sess.created)}"
        )
        self._send_json(
            {"ok": True, "developer": True, "expiresIn": int(sess.expires - time.time())},
            200,
            [("Set-Cookie", cookie)],
        )

    def _api_lock(self) -> None:
        self.ctx.auth.revoke(self._cookie_token())
        cookie = f"{TOKEN_COOKIE}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
        self._send_json({"ok": True, "developer": False}, 200, [("Set-Cookie", cookie)])

    def _api_change_pin(self) -> None:
        """Changing the PIN requires already being unlocked."""
        if not self._is_developer():
            return self._send_json({"ok": False, "error": "unlock first"}, 403)

        body = self._read_json()
        new = str(body.get("newPin", "")).strip()
        try:
            self.ctx.cfg.set_pin(new)
        except ValueError as exc:
            return self._send_json({"ok": False, "error": str(exc)}, 400)

        self.ctx.cfg.save()
        # every existing session dies with the old PIN
        n = self.ctx.auth.revoke_all()
        cookie = f"{TOKEN_COOKIE}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
        self._send_json(
            {"ok": True, "sessionsRevoked": n, "note": "unlock again with the new PIN"},
            200,
            [("Set-Cookie", cookie)],
        )

    # --- state -------------------------------------------------------
    def _shaped_state(self) -> dict:
        dev = self._is_developer()
        snap = self.ctx.poller.snapshot()
        r = self.ctx.redactor

        if not snap.get("ready"):
            return {"ready": False, "developer": dev, "version": snap.get("version", 0)}

        telemetry = {}
        for key, doc in (snap.get("telemetry") or {}).items():
            shaped = dict(doc)
            shaped["data"] = r.telemetry_doc(doc.get("ea", ""), doc.get("data") or {}, dev)
            telemetry[key] = shaped

        return {
            "ready": True,
            "developer": dev,
            "version": snap["version"],
            "serverTs": snap["serverTs"],
            "source": snap["source"],
            "terminal": snap["terminal"],
            "account": r.account(snap.get("account") or {}, dev),
            "positions": r.positions(snap.get("positions") or [], dev),
            "totals": snap["totals"],
            "strategies": snap["strategies"],
            "drawdown": snap["drawdown"],
            "telemetry": telemetry,
            "telemetryHealth": snap["telemetryHealth"],
            "poller": snap["poller"] if dev else {"cycles": snap["poller"]["cycles"]},
        }

    def _api_state(self) -> None:
        self._send_json(self._shaped_state())

    def _api_series(self, query: dict) -> None:
        rng = (query.get("range", ["24h"])[0] or "24h").lower()
        window = RANGES.get(rng, 86400)
        since = 0 if window == 0 else int(time.time()) - window
        self._send_json(
            {
                "range": rng,
                "samples": self.ctx.store.series(since),
                "realised": self.ctx.store.realised_curve(since),
            }
        )

    def _api_trades(self, query: dict) -> None:
        try:
            limit = max(1, min(500, int(query.get("limit", ["100"])[0])))
        except ValueError:
            limit = 100
        rng = (query.get("range", ["7d"])[0] or "7d").lower()
        window = RANGES.get(rng, 7 * 86400)
        since = 0 if window == 0 else int(time.time()) - window
        self._send_json({"trades": self.ctx.store.closed_trades(limit, since)})

    def _api_strategies(self, query: dict) -> None:
        rng = (query.get("range", ["30d"])[0] or "30d").lower()
        window = RANGES.get(rng, 30 * 86400)
        since = 0 if window == 0 else int(time.time()) - window
        self._send_json({"range": rng, "stats": self.ctx.store.strategy_stats(since)})

    def _api_health(self) -> None:
        dev = self._is_developer()
        snap = self.ctx.poller.snapshot()
        out = {
            "ok": True,
            "uptimeSeconds": int(time.time() - self.ctx.started),
            "source": snap.get("source", "?"),
            "ready": bool(snap.get("ready")),
            "developerSessions": self.ctx.auth.active_count(),
            "telemetry": snap.get("telemetryHealth", {}),
        }
        if dev:
            out["store"] = self.ctx.store.stats()
            out["poller"] = snap.get("poller", {})
        self._send_json(out)

    # --- SSE ---------------------------------------------------------
    def _api_events(self) -> None:
        """Push a shaped state document whenever the poller publishes one."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        seen = -1
        last_beat = 0.0
        try:
            while True:
                version = self.ctx.poller.wait_for_change(seen, timeout=20.0)
                now = time.time()

                if version != seen:
                    seen = version
                    payload = json.dumps(
                        self._shaped_state(), separators=(",", ":"), default=str
                    )
                    self.wfile.write(f"event: state\ndata: {payload}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    last_beat = now
                elif now - last_beat > 20:
                    # comment frame keeps proxies from closing an idle stream
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    last_beat = now
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    # --- static ------------------------------------------------------
    def _serve_static(self, route: str) -> None:
        if route in ("/", ""):
            route = "/index.html"

        # normalise and confine to the frontend directory
        clean = posixpath.normpath(route).lstrip("/")
        target = (self.ctx.frontend_dir / clean).resolve()
        root = self.ctx.frontend_dir.resolve()
        if not str(target).startswith(str(root)):
            return self._send_json({"error": "forbidden"}, 403)
        if not target.is_file():
            return self._send_json({"error": "not found", "path": route}, 404)

        ctype, _ = mimetypes.guess_type(str(target))
        if target.suffix == ".js":
            ctype = "text/javascript; charset=utf-8"
        elif target.suffix == ".css":
            ctype = "text/css; charset=utf-8"
        elif target.suffix == ".html":
            ctype = "text/html; charset=utf-8"
        ctype = ctype or "application/octet-stream"

        data = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)


def make_server(ctx: Context, host: str, port: int) -> ThreadingHTTPServer:
    handler = type("BoundHandler", (Handler,), {"ctx": ctx})
    httpd = ThreadingHTTPServer((host, port), handler)
    httpd.daemon_threads = True
    return httpd
