"""
SQLite persistence for the curves and the closed-trade log.

Two tables carry the history the dashboard draws:

  samples   one row per sample interval: balance, equity, floating PnL,
            margin, and the running drawdown against the equity peak
  closed    one row per closing deal, with the EA and strategy that
            opened it resolved at write time

The equity peak lives in a meta row rather than being recomputed, so
drawdown survives a backend restart instead of resetting to zero and
showing a misleadingly healthy curve.

Standard library sqlite3 only. Every method is safe to call from the
poller thread and the HTTP threads: a lock serialises writes and each
connection is opened per thread.
"""

from __future__ import annotations

import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
    ts            INTEGER PRIMARY KEY,
    balance       REAL NOT NULL,
    equity        REAL NOT NULL,
    floating      REAL NOT NULL,
    margin        REAL NOT NULL,
    free_margin   REAL NOT NULL,
    margin_level  REAL NOT NULL,
    positions     INTEGER NOT NULL,
    lots          REAL NOT NULL,
    peak_equity   REAL NOT NULL,
    drawdown      REAL NOT NULL,
    drawdown_pct  REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS closed (
    deal_id     INTEGER PRIMARY KEY,
    position_id INTEGER,
    ts          INTEGER NOT NULL,
    symbol      TEXT NOT NULL,
    magic       INTEGER NOT NULL,
    comment     TEXT,
    ea_tag      TEXT,
    ea_name     TEXT,
    strategy    TEXT,
    side        TEXT,
    volume      REAL,
    price       REAL,
    profit      REAL,
    swap        REAL,
    commission  REAL,
    net         REAL
);

CREATE INDEX IF NOT EXISTS idx_closed_ts       ON closed(ts);
CREATE INDEX IF NOT EXISTS idx_closed_strategy ON closed(strategy);
CREATE INDEX IF NOT EXISTS idx_samples_ts      ON samples(ts);

CREATE TABLE IF NOT EXISTS meta (
    k TEXT PRIMARY KEY,
    v TEXT
);
"""


class Store:
    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        self._lock = threading.Lock()
        self._local = threading.local()
        with self._conn() as c:
            c.executescript(SCHEMA)

    # -----------------------------------------------------------------
    def _conn(self) -> sqlite3.Connection:
        conn = getattr(self._local, "conn", None)
        if conn is None:
            conn = sqlite3.connect(self.path, timeout=10.0)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            self._local.conn = conn
        return conn

    def close(self) -> None:
        conn = getattr(self._local, "conn", None)
        if conn is not None:
            conn.close()
            self._local.conn = None

    # --- meta --------------------------------------------------------
    def get_meta(self, key: str, default: str = "") -> str:
        row = self._conn().execute("SELECT v FROM meta WHERE k=?", (key,)).fetchone()
        return row["v"] if row else default

    def set_meta(self, key: str, value: str) -> None:
        with self._lock, self._conn() as c:
            c.execute(
                "INSERT INTO meta(k,v) VALUES(?,?) "
                "ON CONFLICT(k) DO UPDATE SET v=excluded.v",
                (key, str(value)),
            )

    def peak_equity(self) -> float:
        try:
            return float(self.get_meta("peak_equity", "0") or 0.0)
        except ValueError:
            return 0.0

    # --- samples -----------------------------------------------------
    def add_sample(
        self,
        *,
        ts: int,
        balance: float,
        equity: float,
        floating: float,
        margin: float,
        free_margin: float,
        margin_level: float,
        positions: int,
        lots: float,
    ) -> dict[str, float]:
        """Persist one sample and return the drawdown figures for it."""
        peak = self.peak_equity()
        if equity > peak:
            peak = equity
            self.set_meta("peak_equity", f"{peak:.2f}")

        dd = max(0.0, peak - equity)
        dd_pct = (dd / peak * 100.0) if peak > 0 else 0.0

        with self._lock, self._conn() as c:
            c.execute(
                "INSERT INTO samples(ts,balance,equity,floating,margin,free_margin,"
                "margin_level,positions,lots,peak_equity,drawdown,drawdown_pct) "
                "VALUES(?,?,?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(ts) DO UPDATE SET "
                "balance=excluded.balance, equity=excluded.equity, "
                "floating=excluded.floating, margin=excluded.margin, "
                "free_margin=excluded.free_margin, margin_level=excluded.margin_level, "
                "positions=excluded.positions, lots=excluded.lots, "
                "peak_equity=excluded.peak_equity, drawdown=excluded.drawdown, "
                "drawdown_pct=excluded.drawdown_pct",
                (
                    int(ts), float(balance), float(equity), float(floating),
                    float(margin), float(free_margin), float(margin_level),
                    int(positions), float(lots), float(peak), float(dd), float(dd_pct),
                ),
            )

        return {"peak": peak, "drawdown": dd, "drawdownPct": dd_pct}

    def series(self, since_ts: int, max_points: int = 900) -> list[dict[str, Any]]:
        """Samples since a timestamp, thinned to at most max_points.

        Thinning is done with a modulo on the row number so the shape of
        the curve is preserved; returning every row would make a 45-day
        range many thousands of points for no visual gain.
        """
        conn = self._conn()
        total = conn.execute(
            "SELECT COUNT(*) AS n FROM samples WHERE ts>=?", (int(since_ts),)
        ).fetchone()["n"]
        if total == 0:
            return []

        stride = max(1, total // max(1, max_points))
        rows = conn.execute(
            """
            SELECT * FROM (
                SELECT *, ROW_NUMBER() OVER (ORDER BY ts) AS rn
                FROM samples WHERE ts>=?
            )
            WHERE rn % ? = 0 OR rn = 1 OR rn = ?
            ORDER BY ts
            """,
            (int(since_ts), stride, total),
        ).fetchall()

        return [
            {
                "ts": r["ts"],
                "balance": r["balance"],
                "equity": r["equity"],
                "floating": r["floating"],
                "drawdown": r["drawdown"],
                "drawdownPct": r["drawdown_pct"],
                "positions": r["positions"],
                "lots": r["lots"],
                "marginLevel": r["margin_level"],
            }
            for r in rows
        ]

    def latest_sample(self) -> dict[str, Any] | None:
        r = self._conn().execute(
            "SELECT * FROM samples ORDER BY ts DESC LIMIT 1"
        ).fetchone()
        return dict(r) if r else None

    # --- closed trades ----------------------------------------------
    def add_closed(self, rows: list[dict[str, Any]]) -> int:
        """Insert closing deals, ignoring ones already recorded."""
        if not rows:
            return 0
        added = 0
        with self._lock, self._conn() as c:
            for r in rows:
                net = float(r.get("profit", 0.0)) + float(r.get("swap", 0.0)) + float(
                    r.get("commission", 0.0)
                )
                cur = c.execute(
                    "INSERT OR IGNORE INTO closed(deal_id,position_id,ts,symbol,magic,"
                    "comment,ea_tag,ea_name,strategy,side,volume,price,profit,swap,"
                    "commission,net) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (
                        int(r.get("dealId", 0)),
                        int(r.get("positionId", 0) or 0),
                        int(r.get("time", 0)),
                        str(r.get("symbol", "")),
                        int(r.get("magic", 0)),
                        str(r.get("comment", "")),
                        str(r.get("eaTag", "")),
                        str(r.get("eaName", "")),
                        str(r.get("strategy", "")),
                        str(r.get("side", "")),
                        float(r.get("volume", 0.0)),
                        float(r.get("price", 0.0)),
                        float(r.get("profit", 0.0)),
                        float(r.get("swap", 0.0)),
                        float(r.get("commission", 0.0)),
                        net,
                    ),
                )
                added += cur.rowcount if cur.rowcount > 0 else 0
        return added

    def closed_trades(self, limit: int = 100, since_ts: int = 0) -> list[dict[str, Any]]:
        rows = self._conn().execute(
            "SELECT * FROM closed WHERE ts>=? ORDER BY ts DESC LIMIT ?",
            (int(since_ts), int(limit)),
        ).fetchall()
        return [
            {
                "dealId": r["deal_id"],
                "ts": r["ts"],
                "symbol": r["symbol"],
                "eaTag": r["ea_tag"],
                "eaName": r["ea_name"],
                "strategy": r["strategy"],
                "side": r["side"],
                "volume": r["volume"],
                "price": r["price"],
                "profit": r["profit"],
                "swap": r["swap"],
                "commission": r["commission"],
                "net": r["net"],
                "comment": r["comment"],
                "magic": r["magic"],
            }
            for r in rows
        ]

    def strategy_stats(self, since_ts: int = 0) -> list[dict[str, Any]]:
        """Per-strategy realised performance. This is the honest scoreboard
        for which layer is actually earning."""
        rows = self._conn().execute(
            """
            SELECT strategy, ea_tag,
                   COUNT(*)                          AS trades,
                   SUM(CASE WHEN net > 0 THEN 1 ELSE 0 END) AS wins,
                   SUM(net)                          AS net,
                   AVG(net)                          AS avg_net,
                   MAX(net)                          AS best,
                   MIN(net)                          AS worst
            FROM closed
            WHERE ts >= ? AND strategy != ''
            GROUP BY strategy, ea_tag
            ORDER BY net DESC
            """,
            (int(since_ts),),
        ).fetchall()
        out = []
        for r in rows:
            trades = r["trades"] or 0
            wins = r["wins"] or 0
            out.append(
                {
                    "strategy": r["strategy"],
                    "eaTag": r["ea_tag"],
                    "trades": trades,
                    "wins": wins,
                    "winRate": round(wins / trades * 100.0, 1) if trades else 0.0,
                    "net": round(r["net"] or 0.0, 2),
                    "avgNet": round(r["avg_net"] or 0.0, 2),
                    "best": round(r["best"] or 0.0, 2),
                    "worst": round(r["worst"] or 0.0, 2),
                }
            )
        return out

    def realised_curve(self, since_ts: int, max_points: int = 600) -> list[dict[str, Any]]:
        """Cumulative realised PnL from the closed-trade log."""
        rows = self._conn().execute(
            "SELECT ts, net FROM closed WHERE ts>=? ORDER BY ts", (int(since_ts),)
        ).fetchall()
        if not rows:
            return []
        stride = max(1, len(rows) // max(1, max_points))
        out, run = [], 0.0
        for i, r in enumerate(rows):
            run += r["net"] or 0.0
            if i % stride == 0 or i == len(rows) - 1:
                out.append({"ts": r["ts"], "cum": round(run, 2)})
        return out

    # --- housekeeping -----------------------------------------------
    def prune(self, retention_days: int) -> int:
        if retention_days <= 0:
            return 0
        cutoff = int(time.time()) - retention_days * 86400
        with self._lock, self._conn() as c:
            n = c.execute("DELETE FROM samples WHERE ts < ?", (cutoff,)).rowcount
        return max(0, n)

    def stats(self) -> dict[str, Any]:
        conn = self._conn()
        s = conn.execute(
            "SELECT COUNT(*) AS n, MIN(ts) AS a, MAX(ts) AS b FROM samples"
        ).fetchone()
        c = conn.execute("SELECT COUNT(*) AS n FROM closed").fetchone()
        size = 0
        try:
            size = Path(self.path).stat().st_size
        except OSError:
            pass
        return {
            "samples": s["n"] or 0,
            "firstSample": s["a"] or 0,
            "lastSample": s["b"] or 0,
            "closedTrades": c["n"] or 0,
            "dbBytes": size,
            "peakEquity": self.peak_equity(),
        }
