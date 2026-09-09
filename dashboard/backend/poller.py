"""
The background worker.

One thread does all the reading so the HTTP handlers never block on MT5 or
on the filesystem: they only ever serve the last snapshot it published.

Each cycle it
  - reads account and positions from the terminal
  - resolves which EA and strategy opened every position
  - reads the EA telemetry documents
  - ingests any newly closed deals into the trade log
  - writes an equity / PnL / drawdown sample on the sample interval
  - publishes an immutable snapshot and bumps a version counter

The version counter is what the SSE endpoint watches, so browsers are
pushed an update exactly when something actually changed.
"""

from __future__ import annotations

import threading
import time
import traceback
from typing import Any

from .attribution import attribute
from .mt5source import MarketSource
from .store import Store
from .telemetry import TelemetryReader

#: watermark key for deal ingestion, so a restart does not rescan history
META_DEAL_TS = "last_deal_ts"


class Poller:
    def __init__(
        self,
        *,
        source: MarketSource,
        store: Store,
        telemetry: TelemetryReader,
        magic_base: int,
        poll_seconds: int = 2,
        sample_seconds: int = 15,
        retention_days: int = 45,
    ) -> None:
        self.source = source
        self.store = store
        self.telemetry = telemetry
        self.magic_base = magic_base
        self.poll_seconds = max(1, poll_seconds)
        self.sample_seconds = max(5, sample_seconds)
        self.retention_days = retention_days

        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._cond = threading.Condition()

        self._snapshot: dict[str, Any] = {"ready": False, "version": 0}
        self._version = 0
        self._last_sample = 0.0
        self._last_prune = 0.0
        self._errors: list[str] = []
        self.cycles = 0

    # -----------------------------------------------------------------
    def start(self) -> None:
        if self._thread is not None:
            return
        # Ask the terminal where its data folder is, but never overwrite a
        # directory the caller set explicitly - a configured override has to
        # win, and clobbering it here left the first snapshot with no
        # telemetry at all.
        if self.telemetry.directory is None:
            self.telemetry.set_dir(self.source.telemetry_dir())
        self._thread = threading.Thread(target=self._run, name="km-poller", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        with self._cond:
            self._cond.notify_all()
        if self._thread is not None:
            self._thread.join(timeout=5.0)
            self._thread = None

    # -----------------------------------------------------------------
    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return self._snapshot

    def version(self) -> int:
        with self._lock:
            return self._version

    def wait_for_change(self, seen: int, timeout: float = 25.0) -> int:
        """Block until the snapshot version moves past `seen`."""
        deadline = time.time() + timeout
        with self._cond:
            while True:
                with self._lock:
                    cur = self._version
                if cur != seen:
                    return cur
                remaining = deadline - time.time()
                if remaining <= 0:
                    return cur
                self._cond.wait(timeout=min(1.0, remaining))

    # -----------------------------------------------------------------
    def _run(self) -> None:
        while not self._stop.is_set():
            started = time.time()
            try:
                self._cycle()
            except Exception:
                msg = traceback.format_exc(limit=3)
                self._note_error(msg.strip().splitlines()[-1])
            self.cycles += 1

            elapsed = time.time() - started
            self._stop.wait(max(0.2, self.poll_seconds - elapsed))

    def _note_error(self, msg: str) -> None:
        with self._lock:
            self._errors.append(f"{int(time.time())}: {msg}")
            del self._errors[:-10]

    # -----------------------------------------------------------------
    def _cycle(self) -> None:
        now = time.time()

        account = self.source.account()
        raw_positions = self.source.positions()
        terminal = self.source.terminal()

        # the telemetry folder can appear after start-up, e.g. once the
        # first EA writes a snapshot
        if self.telemetry.directory is None:
            self.telemetry.set_dir(self.source.telemetry_dir())

        snaps = self.telemetry.read_all()

        positions = self._shape_positions(raw_positions)
        totals = self._totals(positions)
        strategies = self._live_by_strategy(positions)

        self._ingest_deals(now)

        dd = {"peak": self.store.peak_equity(), "drawdown": 0.0, "drawdownPct": 0.0}
        if account and (now - self._last_sample) >= self.sample_seconds:
            dd = self.store.add_sample(
                ts=int(now),
                balance=float(account.get("balance", 0.0)),
                equity=float(account.get("equity", 0.0)),
                floating=totals["profit"],
                margin=float(account.get("margin", 0.0)),
                free_margin=float(account.get("freeMargin", 0.0)),
                margin_level=float(account.get("marginLevel", 0.0)),
                positions=totals["count"],
                lots=totals["lots"],
            )
            self._last_sample = now
        elif account:
            peak = self.store.peak_equity()
            eq = float(account.get("equity", 0.0))
            drop = max(0.0, peak - eq)
            dd = {
                "peak": peak,
                "drawdown": drop,
                "drawdownPct": (drop / peak * 100.0) if peak > 0 else 0.0,
            }

        if (now - self._last_prune) > 3600:
            self.store.prune(self.retention_days)
            self._last_prune = now

        telemetry_docs = {k: s.to_dict() for k, s in snaps.items()}

        snapshot = {
            "ready": True,
            "version": self._version + 1,
            "serverTs": int(now),
            "source": self.source.kind,
            "terminal": terminal,
            "account": account,
            "positions": positions,
            "totals": totals,
            "strategies": strategies,
            "drawdown": {
                "peakEquity": round(dd["peak"], 2),
                "current": round(dd["drawdown"], 2),
                "currentPct": round(dd["drawdownPct"], 2),
            },
            "telemetry": telemetry_docs,
            "telemetryHealth": self.telemetry.health(snaps),
            "poller": {
                "cycles": self.cycles,
                "pollSeconds": self.poll_seconds,
                "sampleSeconds": self.sample_seconds,
                "errors": list(self._errors[-5:]),
            },
        }

        with self._lock:
            self._version += 1
            snapshot["version"] = self._version
            self._snapshot = snapshot
        with self._cond:
            self._cond.notify_all()

    # -----------------------------------------------------------------
    def _shape_positions(self, rows: list[dict]) -> list[dict]:
        out = []
        now = int(time.time())
        for p in rows:
            a = attribute(p.get("magic", 0), p.get("comment", ""), self.magic_base)
            if not a.in_family:
                # something else is trading this account; show it but mark
                # it, rather than pretending it belongs to the suite
                pass

            side = "BUY" if p.get("type") == 0 else "SELL"
            opened = int(p.get("time", 0))
            row = {
                "ticket": p.get("ticket"),
                "symbol": p.get("symbol", ""),
                "side": side,
                "volume": p.get("volume", 0.0),
                "priceOpen": p.get("priceOpen", 0.0),
                "priceCurrent": p.get("priceCurrent", 0.0),
                "tp": p.get("tp", 0.0),
                "sl": p.get("sl", 0.0),
                "profit": round(float(p.get("profit", 0.0)), 2),
                "swap": round(float(p.get("swap", 0.0)), 2),
                "openedTs": opened,
                "ageSeconds": max(0, now - opened) if opened else 0,
                "hasOwnTp": bool(p.get("tp")),
            }
            row.update(a.to_dict())
            row["rawComment"] = a.raw_comment
            row["magic"] = a.raw_magic
            if a.parse_note:
                row["parseNote"] = a.parse_note
            out.append(row)

        out.sort(key=lambda r: (r["symbol"], r.get("eaSlot") or 99, -r["ageSeconds"]))
        return out

    def _totals(self, positions: list[dict]) -> dict[str, Any]:
        count = len(positions)
        lots = round(sum(float(p["volume"]) for p in positions), 2)
        profit = round(sum(float(p["profit"]) for p in positions), 2)
        buy = sum(1 for p in positions if p["side"] == "BUY")
        withtp = sum(1 for p in positions if p["hasOwnTp"])
        symbols = sorted({p["symbol"] for p in positions})
        return {
            "count": count,
            "lots": lots,
            "profit": profit,
            "buyCount": buy,
            "sellCount": count - buy,
            "withOwnTp": withtp,
            "symbols": symbols,
        }

    def _live_by_strategy(self, positions: list[dict]) -> list[dict]:
        """Open exposure grouped by the strategy that opened it. This is an
        outcome, not a signal vote, so it stays visible in normal mode."""
        acc: dict[str, dict[str, Any]] = {}
        for p in positions:
            key = p.get("strategy") or "unattributed"
            slot = acc.setdefault(
                key,
                {
                    "strategy": key,
                    "strategyLabel": p.get("strategyLabel", key),
                    "eaTag": p.get("eaTag", ""),
                    "count": 0,
                    "lots": 0.0,
                    "profit": 0.0,
                    "buy": 0,
                    "sell": 0,
                    "symbols": set(),
                },
            )
            slot["count"] += 1
            slot["lots"] += float(p["volume"])
            slot["profit"] += float(p["profit"])
            slot["buy" if p["side"] == "BUY" else "sell"] += 1
            slot["symbols"].add(p["symbol"])

        out = []
        for v in acc.values():
            v["lots"] = round(v["lots"], 2)
            v["profit"] = round(v["profit"], 2)
            v["symbols"] = sorted(v["symbols"])
            out.append(v)
        out.sort(key=lambda r: (-r["count"], r["strategy"]))
        return out

    # -----------------------------------------------------------------
    def _ingest_deals(self, now: float) -> None:
        """Pull closing deals since the watermark and record them."""
        try:
            last = int(self.store.get_meta(META_DEAL_TS, "0") or 0)
        except ValueError:
            last = 0

        if last == 0:
            # first run: look back a week rather than the whole history
            last = int(now) - 7 * 86400

        deals = self.source.deals_since(last)
        if not deals:
            return

        rows = []
        newest = last
        for d in deals:
            newest = max(newest, int(d.get("time", 0)))
            # entry 1 is DEAL_ENTRY_OUT: the close, which carries the P/L
            if int(d.get("entry", 0)) != 1:
                continue
            a = attribute(d.get("magic", 0), d.get("comment", ""), self.magic_base)
            rows.append(
                {
                    **d,
                    "eaTag": a.ea_tag,
                    "eaName": a.ea_name,
                    "strategy": a.strategy,
                    # the deal's own type is the closing direction, so the
                    # position's side is the opposite
                    "side": a.side or ("SELL" if int(d.get("type", 0)) == 0 else "BUY"),
                }
            )

        added = self.store.add_closed(rows)
        if newest > last:
            self.store.set_meta(META_DEAL_TS, str(newest))
        if added:
            print(f"[poller] recorded {added} closed trade(s)")
