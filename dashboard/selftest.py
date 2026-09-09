#!/usr/bin/env python3
"""
End-to-end check of the dashboard backend.

Starts the real HTTP server on an ephemeral port in a thread, drives it
with urllib, then shuts down. No external test framework, no network.

Verifies the things that would actually break in production:
  - the poller produces a snapshot from the source
  - positions are attributed to the right EA and strategy
  - SQLite samples and the closed-trade log are written
  - normal mode leaks none of the developer-only fields
  - the PIN unlocks developer mode, a wrong PIN does not, and repeated
    wrong PINs get rate limited
  - the SSE stream emits a state frame
"""

from __future__ import annotations

import json
import sys
import threading
import time
import urllib.error
import urllib.request
from http.cookiejar import CookieJar
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from backend.auth import AuthManager  # noqa: E402
from backend.config import Config  # noqa: E402
from backend.mt5source import DemoSource  # noqa: E402
from backend.poller import Poller  # noqa: E402
from backend.redact import FORBIDDEN_IN_NORMAL, Redactor  # noqa: E402
from backend.server import Context, make_server  # noqa: E402
from backend.store import Store  # noqa: E402
from backend.telemetry import TelemetryReader  # noqa: E402

FAILURES: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + (f"  {detail}" if detail else ""))
    if not ok:
        FAILURES.append(label)


def deep_keys(obj, acc=None):
    acc = acc if acc is not None else set()
    if isinstance(obj, dict):
        for k, v in obj.items():
            acc.add(k)
            deep_keys(v, acc)
    elif isinstance(obj, list):
        for v in obj:
            deep_keys(v, acc)
    return acc


def main() -> int:
    tmp = HERE / ".selftest"
    tmp.mkdir(exist_ok=True)
    for stale in tmp.glob("*"):
        if stale.is_file():
            stale.unlink()

    # --- a telemetry fixture, shaped exactly like what the EAs write ---
    teldir = tmp / "telemetry"
    teldir.mkdir(exist_ok=True)
    (teldir / "KM1_XAUUSD.json").write_text(
        json.dumps(
            {
                "ea": "KM1", "symbol": "XAUUSD", "ts": int(time.time()),
                "time": "2026.09.07 12:00:00", "suiteVer": "1.00",
                "market": {"bid": 2650.35, "ask": 2650.55, "spreadPts": 20,
                           "digits": 2, "moneyPerLot": 100.0},
                "view": {"score": 62.4, "regime": "TREND-UP", "vol": "NORMAL",
                         "atr": 6.1, "rsi": 58.2, "adx": 27.3, "mtfAgree": True},
                "gate": {"evaluated": 84213, "entries": 18, "lastTrigger": "PLAYBOOK",
                         "scoreBest": 58.2,
                         "floors": {"minScore": 35.0, "minAdx": 18.0},
                         "blocks": [{"name": "score below floor", "count": 52104}]},
                "layers": [{"name": "INSIDEBAR", "qualified": 140, "entered": 12,
                            "enabled": True}],
                "playbook": {"valid": True, "edge": "S/R+RSIdivergence", "dir": "LONG",
                             "confidence": 78.0,
                             "narrative": "1) UPTREND\n2) sup 2648.20\n3) vwap -1.42 sd"},
                "telemetry": {"writes": 1204, "failures": 0, "lastError": ""},
            }
        ),
        encoding="utf-8",
    )

    cfg = Config.load(tmp / "config.json")
    cfg.magic_base = 51000
    cfg.poll_seconds = 1
    cfg.sample_seconds = 1
    cfg.db_path = str(tmp / "test.sqlite3")
    pin = cfg.ensure_pin() or "123456"

    source = DemoSource(magic_base=cfg.magic_base)
    source.connect()
    store = Store(cfg.db_path)
    tel = TelemetryReader(stale_seconds=90)
    tel.set_dir(teldir)

    poller = Poller(
        source=source, store=store, telemetry=tel,
        magic_base=cfg.magic_base, poll_seconds=1, sample_seconds=1,
        retention_days=45,
    )
    poller.start()
    # the poller sets the telemetry dir from the terminal on start; the demo
    # terminal has no data path, so point it back at the fixture
    tel.set_dir(teldir)

    auth = AuthManager(session_minutes=10, max_attempts=3,
                       window_seconds=60, lockout_seconds=30)
    ctx = Context(cfg=cfg, auth=auth, redactor=Redactor(), poller=poller,
                  store=store, frontend_dir=HERE / "frontend")

    httpd = make_server(ctx, "127.0.0.1", 0)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.2},
                     daemon=True).start()
    base = f"http://127.0.0.1:{port}"

    jar = CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    def get(path):
        try:
            with opener.open(base + path, timeout=10) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            # a 404 is a valid answer to test, not a transport failure
            try:
                return e.code, json.loads(e.read().decode())
            except Exception:
                return e.code, {}

    def post(path, body):
        req = urllib.request.Request(
            base + path,
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with opener.open(req, timeout=10) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode())

    print("\n=== poller and data source ===")
    deadline = time.time() + 15
    st = {}
    while time.time() < deadline:
        _, st = get("/api/state")
        if st.get("ready"):
            break
        time.sleep(0.4)
    check("poller produced a snapshot", bool(st.get("ready")))
    check("source is the demo book", st.get("source") == "demo", st.get("source", ""))
    check("positions present", len(st.get("positions") or []) > 0,
          f"{len(st.get('positions') or [])} open")

    print("\n=== strategy attribution per order ===")
    by_strat = {}
    for p in st.get("positions", []):
        by_strat.setdefault(p.get("strategy", "?"), 0)
        by_strat[p["strategy"]] += 1
    for p in st.get("positions", [])[:6]:
        print(f"       {p['symbol']:8} {p['side']:4} {p['volume']:>5} "
              f"{p.get('eaTag',''):4} {p.get('strategy',''):10} {p.get('strategyLabel','')}")
    check("every position attributed to an EA",
          all(p.get("eaTag") for p in st.get("positions", [])))
    check("multiple strategies represented", len(by_strat) >= 4, str(sorted(by_strat)))
    check("grid legs attributed to KM2",
          any(p.get("strategy") == "GRID" for p in st.get("positions", [])))
    check("recovery leg attributed to KM3",
          any(p.get("strategy") == "RECOVERY" for p in st.get("positions", [])))
    check("cross-asset assist attributed to KM5",
          any(p.get("strategy") == "ASSIST" for p in st.get("positions", [])))

    print("\n=== normal mode: no developer-only field leaks ===")
    leaked = sorted(deep_keys(st) & set(FORBIDDEN_IN_NORMAL))
    check("state has no forbidden keys", not leaked, str(leaked))
    check("developer flag is false", st.get("developer") is False)
    km1 = (st.get("telemetry") or {}).get("KM1_XAUUSD", {}).get("data", {})
    check("telemetry doc marked redacted", km1.get("redacted") is True)
    check("score hidden in normal mode", "score" not in (km1.get("view") or {}))
    check("narrative hidden in normal mode", "narrative" not in json.dumps(km1))
    check("strategy name still visible",
          any(p.get("strategy") for p in st.get("positions", [])))

    print("\n=== developer mode via PIN ===")
    code, body = post("/api/unlock", {"pin": "000000" if pin != "000000" else "111111"})
    check("wrong PIN rejected", code == 401 and body.get("ok") is False,
          f"attemptsLeft={body.get('attemptsLeft')}")
    code, body = post("/api/unlock", {"pin": pin})
    check("correct PIN accepted", code == 200 and body.get("developer") is True)

    _, dev = get("/api/state")
    check("developer flag now true", dev.get("developer") is True)
    dkm1 = (dev.get("telemetry") or {}).get("KM1_XAUUSD", {}).get("data", {})
    check("score visible in developer mode", "score" in (dkm1.get("view") or {}),
          str((dkm1.get("view") or {}).get("score")))
    check("block histogram visible", bool((dkm1.get("gate") or {}).get("blocks")))
    check("qualified counts visible",
          "qualified" in json.dumps(dkm1.get("layers") or []))
    check("narrative visible", "narrative" in (dkm1.get("playbook") or {}))

    print("\n=== lock again ===")
    post("/api/lock", {})
    _, relocked = get("/api/state")
    check("re-locked", relocked.get("developer") is False)
    check("score hidden again",
          "score" not in ((relocked.get("telemetry") or {})
                          .get("KM1_XAUUSD", {}).get("data", {}).get("view") or {}))

    print("\n=== brute-force protection ===")
    jar2 = CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar2))
    codes = []
    for _ in range(4):
        c, b = post("/api/unlock", {"pin": "999999"})
        codes.append((c, b.get("retryAfter")))
    locked = any(c == 429 or r for c, r in codes)
    check("repeated wrong PINs trigger a lockout", locked, str(codes))

    print("\n=== persistence ===")
    time.sleep(2.0)
    _, series = get("/api/series?range=1h")
    check("equity samples stored", len(series.get("samples") or []) >= 1,
          f"{len(series.get('samples') or [])} points")
    s = store.stats()
    check("sqlite has rows", s["samples"] >= 1, str(s))
    sample = (series.get("samples") or [{}])[-1]
    check("sample carries equity and drawdown",
          "equity" in sample and "drawdown" in sample, str(sample)[:110])

    print("\n=== other endpoints ===")
    for path in ("/api/session", "/api/health", "/api/trades?limit=5",
                 "/api/strategies?range=30d"):
        try:
            c, b = get(path)
            check(f"GET {path}", c == 200, f"keys={sorted(b)[:4]}")
        except Exception as exc:
            check(f"GET {path}", False, str(exc))
    c, b = get("/api/nope")
    check("unknown endpoint 404s", c == 404 or b.get("error") == "unknown endpoint")

    print("\n=== SSE stream ===")
    got_frame = False
    try:
        req = urllib.request.Request(base + "/api/events")
        with urllib.request.urlopen(req, timeout=12) as r:
            buf = b""
            end = time.time() + 10
            while time.time() < end:
                chunk = r.read(1)
                if not chunk:
                    break
                buf += chunk
                if b"event: state" in buf and buf.count(b"\n\n") >= 1:
                    got_frame = True
                    break
    except Exception as exc:
        print(f"       SSE error: {exc}")
    check("SSE emitted a state frame", got_frame)

    print("\n=== static files confined to the frontend dir ===")
    try:
        with opener.open(base + "/../backend/config.py", timeout=5) as r:
            body = r.read()
        escaped = b"pin_hash" in body
    except urllib.error.HTTPError:
        escaped = False
    except Exception:
        escaped = False
    check("path traversal blocked", not escaped)

    httpd.shutdown()
    poller.stop()
    store.close()
    httpd.server_close()

    print("\n" + "=" * 62)
    if FAILURES:
        print(f"FAILED ({len(FAILURES)}): " + ", ".join(FAILURES))
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
