"""
Entry point: wires the pieces together and runs until interrupted.

Nothing here needs installing beyond the MetaTrader5 package, and that is
only required for a live terminal - without it the dashboard falls back to
a synthetic book so the UI can still be opened and judged.
"""

from __future__ import annotations

import argparse
import signal
import sys
import time
from pathlib import Path

from .auth import AuthManager
from .config import Config
from .mt5source import build_source
from .poller import Poller
from .redact import Redactor
from .server import Context, make_server
from .store import Store
from .telemetry import TelemetryReader

HERE = Path(__file__).resolve().parent
DASHBOARD_DIR = HERE.parent
FRONTEND_DIR = DASHBOARD_DIR / "frontend"
DEFAULT_CONFIG = DASHBOARD_DIR / "config.json"

BANNER = r"""
  KrishMix Dashboard
  ------------------
"""


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="krishmix-dashboard",
        description="Live dashboard for the KrishMix MT5 suite (read only).",
    )
    p.add_argument("--config", default=str(DEFAULT_CONFIG), help="path to config.json")
    p.add_argument("--host", default=None, help="bind address (default 127.0.0.1)")
    p.add_argument("--port", type=int, default=None, help="port (default 8734)")
    p.add_argument("--magic-base", type=int, default=None, help="must match the EAs")
    p.add_argument("--demo", action="store_true", help="force the synthetic demo book")
    p.add_argument("--set-pin", default=None, help="set the developer-mode PIN and exit")
    p.add_argument(
        "--telemetry-dir",
        default=None,
        help="override where the EA JSON snapshots are read from",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    cfg = Config.load(args.config)

    # command line wins over the file, and is persisted so the next run
    # behaves the same way
    if args.host is not None:
        cfg.host = args.host
    if args.port is not None:
        cfg.port = args.port
    if args.magic_base is not None:
        cfg.magic_base = args.magic_base
    if args.demo:
        cfg.force_demo = True
    if args.telemetry_dir is not None:
        cfg.telemetry_dir = args.telemetry_dir

    if args.set_pin is not None:
        try:
            cfg.set_pin(args.set_pin)
        except ValueError as exc:
            print(f"[pin] {exc}")
            return 2
        cfg.save()
        print("[pin] developer-mode PIN updated. Only its hash is stored.")
        return 0

    cfg.save()

    print(BANNER.rstrip())

    # --- developer-mode PIN -----------------------------------------
    fresh_pin = cfg.ensure_pin()
    if fresh_pin:
        print("  DEVELOPER MODE PIN (shown once, write it down):")
        print(f"      {fresh_pin}")
        print("  Change it any time with:  python run.py --set-pin <newpin>")
        print()

    # --- redaction sanity check -------------------------------------
    redactor = Redactor(hide_money_in_normal=cfg.hide_money_in_normal)
    problems = redactor.self_check()
    if problems:
        print("  REDACTION SELF-CHECK FAILED, refusing to start:")
        for p in problems:
            print(f"    - {p}")
        return 3

    # --- wire it up --------------------------------------------------
    source = build_source(cfg)
    if not source.connect():
        print("  could not connect to any data source")
        return 4

    db_path = cfg.db_path
    if not Path(db_path).is_absolute():
        db_path = str(DASHBOARD_DIR / db_path)
    store = Store(db_path)

    telemetry = TelemetryReader(stale_seconds=cfg.telemetry_stale_seconds)
    if cfg.telemetry_dir:
        telemetry.set_dir(cfg.telemetry_dir)

    poller = Poller(
        source=source,
        store=store,
        telemetry=telemetry,
        magic_base=cfg.magic_base,
        poll_seconds=cfg.poll_seconds,
        sample_seconds=cfg.sample_seconds,
        retention_days=cfg.retention_days,
    )
    # Poller.start() only asks the terminal for its data folder when no
    # directory has been set, so an explicit override survives.
    poller.start()

    auth = AuthManager(
        session_minutes=cfg.session_minutes,
        max_attempts=cfg.unlock_max_attempts,
        window_seconds=cfg.unlock_window_seconds,
        lockout_seconds=cfg.unlock_lockout_seconds,
    )

    ctx = Context(
        cfg=cfg,
        auth=auth,
        redactor=redactor,
        poller=poller,
        store=store,
        frontend_dir=FRONTEND_DIR,
    )

    httpd = make_server(ctx, cfg.host, cfg.port)

    shown = cfg.host if cfg.host not in ("0.0.0.0", "") else "127.0.0.1"
    print(f"  data source     : {source.kind}")
    print(f"  telemetry folder: {telemetry.dir_status().get('path') or '(not located yet)'}")
    print(f"  database        : {db_path}")
    print(f"  dashboard       : http://{shown}:{cfg.port}/")
    if cfg.host not in ("127.0.0.1", "localhost"):
        print()
        print("  NOTE: bound beyond loopback. A PIN over plain HTTP is weak, so put")
        print("        this behind a TLS reverse proxy or reach it over an SSH tunnel.")
    print()
    print("  Ctrl+C to stop")
    print()

    stopping = False

    def shutdown(signum, frame):  # noqa: ANN001
        nonlocal stopping
        if stopping:
            return
        stopping = True
        print("\n[shutdown] stopping")
        threading_shutdown(httpd)

    def threading_shutdown(server) -> None:  # noqa: ANN001
        import threading

        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, shutdown)
    try:
        signal.signal(signal.SIGTERM, shutdown)
    except (AttributeError, ValueError):
        pass

    try:
        httpd.serve_forever(poll_interval=0.5)
    finally:
        poller.stop()
        source.shutdown()
        store.close()
        httpd.server_close()
        print("[shutdown] done")

    return 0


if __name__ == "__main__":
    sys.exit(main())
