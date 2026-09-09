"""
Where the dashboard gets account, position and deal data from.

Two implementations behind one interface:

  Mt5Source        the real thing, via the MetaTrader5 package. Windows
                   only, and it must run on the same machine as the
                   terminal - that is a hard constraint of the package,
                   not a choice.

  DemoSource       a synthetic book that behaves like the suite: entries
                   with strategy comments, a grid that deepens on the
                   losing side, a recovery hedge, cross-asset assists.
                   Lets the dashboard be opened and judged before it is
                   pointed at a live terminal, and makes the whole stack
                   testable off-Windows.

The MetaTrader5 package deliberately exposes no access to terminal global
variables, which is why the EAs export their reasoning to JSON files
instead of the dashboard reading the state bus directly.
"""

from __future__ import annotations

import math
import random
import time
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any


class MarketSource(ABC):
    """Read-only view of the trading terminal."""

    kind = "abstract"

    @abstractmethod
    def connect(self) -> bool: ...

    @abstractmethod
    def shutdown(self) -> None: ...

    @abstractmethod
    def account(self) -> dict[str, Any]: ...

    @abstractmethod
    def positions(self) -> list[dict[str, Any]]: ...

    @abstractmethod
    def deals_since(self, ts: int) -> list[dict[str, Any]]: ...

    @abstractmethod
    def terminal(self) -> dict[str, Any]: ...

    def telemetry_dir(self) -> Path | None:
        """Folder the EAs write their JSON snapshots into."""
        info = self.terminal()
        data_path = info.get("dataPath") or ""
        if not data_path:
            return None
        return Path(data_path) / "MQL5" / "Files" / "KrishMix" / "telemetry"


# ---------------------------------------------------------------------
# real terminal
# ---------------------------------------------------------------------
class Mt5Source(MarketSource):
    kind = "mt5"

    def __init__(self, terminal_path: str = "") -> None:
        self._mt5 = None
        self._terminal_path = terminal_path
        self.last_error = ""

    def connect(self) -> bool:
        try:
            import MetaTrader5 as mt5  # type: ignore
        except Exception as exc:  # pragma: no cover - platform dependent
            self.last_error = (
                f"MetaTrader5 package unavailable ({exc}). It is Windows only "
                "and must run on the same machine as the terminal."
            )
            return False

        self._mt5 = mt5
        ok = mt5.initialize(self._terminal_path) if self._terminal_path else mt5.initialize()
        if not ok:
            self.last_error = f"mt5.initialize failed: {mt5.last_error()}"
            return False

        self.last_error = ""
        return True

    def shutdown(self) -> None:
        if self._mt5 is not None:
            try:
                self._mt5.shutdown()
            except Exception:
                pass

    def account(self) -> dict[str, Any]:
        if self._mt5 is None:
            return {}
        info = self._mt5.account_info()
        if info is None:
            self.last_error = f"account_info failed: {self._mt5.last_error()}"
            return {}
        return {
            "login": int(info.login),
            "server": str(info.server),
            "currency": str(info.currency),
            "balance": float(info.balance),
            "equity": float(info.equity),
            "profit": float(info.profit),
            "margin": float(info.margin),
            "freeMargin": float(info.margin_free),
            "marginLevel": float(info.margin_level),
            "leverage": int(info.leverage),
            "name": str(info.name),
            "company": str(info.company),
        }

    def positions(self) -> list[dict[str, Any]]:
        if self._mt5 is None:
            return []
        rows = self._mt5.positions_get()
        if rows is None:
            return []
        out = []
        for p in rows:
            out.append(
                {
                    "ticket": int(p.ticket),
                    "symbol": str(p.symbol),
                    "type": int(p.type),  # 0 buy, 1 sell
                    "volume": float(p.volume),
                    "priceOpen": float(p.price_open),
                    "priceCurrent": float(p.price_current),
                    "sl": float(p.sl),
                    "tp": float(p.tp),
                    "profit": float(p.profit),
                    "swap": float(p.swap),
                    "magic": int(p.magic),
                    "comment": str(p.comment or ""),
                    "time": int(p.time),
                }
            )
        return out

    def deals_since(self, ts: int) -> list[dict[str, Any]]:
        if self._mt5 is None:
            return []
        from datetime import datetime, timezone

        frm = datetime.fromtimestamp(max(0, ts), tz=timezone.utc)
        to = datetime.now(tz=timezone.utc)
        rows = self._mt5.history_deals_get(frm, to)
        if rows is None:
            return []

        out = []
        for d in rows:
            # entry 1 = DEAL_ENTRY_OUT, i.e. a close. Those carry the P/L.
            out.append(
                {
                    "dealId": int(d.ticket),
                    "positionId": int(d.position_id),
                    "symbol": str(d.symbol),
                    "type": int(d.type),
                    "entry": int(d.entry),
                    "volume": float(d.volume),
                    "price": float(d.price),
                    "profit": float(d.profit),
                    "swap": float(d.swap),
                    "commission": float(d.commission),
                    "magic": int(d.magic),
                    "comment": str(d.comment or ""),
                    "time": int(d.time),
                }
            )
        return out

    def terminal(self) -> dict[str, Any]:
        if self._mt5 is None:
            return {"connected": False, "dataPath": ""}
        info = self._mt5.terminal_info()
        if info is None:
            return {"connected": False, "dataPath": ""}
        return {
            "connected": bool(info.connected),
            "tradeAllowed": bool(info.trade_allowed),
            "dataPath": str(info.data_path),
            "company": str(info.company),
            "name": str(info.name),
            "build": int(info.build),
        }


# ---------------------------------------------------------------------
# synthetic terminal for demos and off-Windows testing
# ---------------------------------------------------------------------
class DemoSource(MarketSource):
    """A believable stand-in.

    It models the shape the real suite produces: an entry carrying a
    strategy comment, a grid deepening against it, a recovery hedge on the
    worst symbol, and assist legs on other assets. Prices random-walk so
    the equity, PnL and drawdown curves actually move.
    """

    kind = "demo"

    SYMBOLS = [
        # symbol, price, moneyPerPricePerLot, atr, digits
        ("XAUUSD", 2650.0, 100.0, 6.0, 2),
        ("BTCUSD", 65000.0, 1.0, 500.0, 2),
        ("XAGUSD", 30.5, 5000.0, 0.15, 3),
        ("XTIUSD", 70.4, 1000.0, 0.5, 2),
        ("USTEC", 20100.0, 1.0, 80.0, 1),
        ("US30", 43200.0, 1.0, 150.0, 1),
    ]

    def __init__(self, magic_base: int = 51000, seed: int = 7) -> None:
        self.magic_base = magic_base
        self._rnd = random.Random(seed)
        self._px = {s[0]: s[1] for s in self.SYMBOLS}
        self._meta = {s[0]: {"mppl": s[2], "atr": s[3], "digits": s[4]} for s in self.SYMBOLS}
        self._positions: list[dict[str, Any]] = []
        self._deals: list[dict[str, Any]] = []
        self._next_ticket = 500001
        self._next_deal = 900001
        self._balance = 5000.0
        self._t0 = int(time.time())
        self._last_step = 0.0
        self._seed_book()

    # --- helpers -----------------------------------------------------
    def _magic(self, slot: int, is_buy: bool) -> int:
        return self.magic_base + slot * 10 + (1 if is_buy else 2)

    def _open(
        self,
        symbol: str,
        is_buy: bool,
        volume: float,
        slot: int,
        comment: str,
        tp_dist: float = 0.0,
        age_min: int = 0,
    ) -> None:
        px = self._px[symbol]
        d = self._meta[symbol]["digits"]
        open_px = round(px * (1 + self._rnd.uniform(-0.002, 0.002)), d)
        tp = 0.0
        if tp_dist:
            tp = round(open_px + tp_dist if is_buy else open_px - tp_dist, d)
        self._positions.append(
            {
                "ticket": self._next_ticket,
                "symbol": symbol,
                "type": 0 if is_buy else 1,
                "volume": volume,
                "priceOpen": open_px,
                "priceCurrent": px,
                "sl": 0.0,  # the suite never sends a stop loss
                "tp": tp,
                "profit": 0.0,
                "swap": 0.0,
                "magic": self._magic(slot, is_buy),
                "comment": comment,
                "time": self._t0 - age_min * 60,
            }
        )
        self._next_ticket += 1

    def _seed_book(self) -> None:
        # EA1 entries on gold, each tagged with the strategy that fired
        self._open("XAUUSD", True, 0.01, 1, "KM1|PLAYBOOK|s62|TREND-UP", tp_dist=11.0, age_min=95)
        self._open("XAUUSD", False, 0.01, 1, "KM1|INSIDEBAR|s-41|RANGE", tp_dist=16.0, age_min=48)

        # EA2 grid deepening against the buy side
        for lvl, lot, press, exh in ((2, 0.02, 61, False), (3, 0.03, 44, False), (4, 0.04, 28, True)):
            self._open(
                "XAUUSD", True, lot, 2,
                f"KM2|L{lvl}|{'exh' if exh else 'cool'}|p{press}",
                age_min=40 - lvl * 6,
            )

        # EA3 recovery hedge against that basket
        self._open("XAUUSD", False, 0.22, 3, "KM3|R1|dd318|s-64", age_min=18)

        # EA5 portfolio entries and cross-asset assists
        self._open("BTCUSD", True, 0.03, 5, "KM5|ENTRY|s58", tp_dist=900.0, age_min=140)
        self._open("USTEC", False, 0.30, 5, "KM5|ENTRY|s-52", tp_dist=150.0, age_min=70)
        self._open("XAGUSD", False, 0.04, 5, "KM5|ASSIST|XAUUSD|s-57", age_min=15)
        self._open("US30", False, 0.20, 5, "KM5|ASSIST|XAUUSD|s-61", age_min=12)

    # --- interface ---------------------------------------------------
    def connect(self) -> bool:
        return True

    def shutdown(self) -> None:
        pass

    def _step_prices(self) -> None:
        """Random-walk each symbol, scaled by its own ATR, at most a few
        times a second so repeated polls do not over-shake the book."""
        now = time.time()
        if now - self._last_step < 0.5:
            return
        self._last_step = now

        for sym, m in self._meta.items():
            drift = self._rnd.gauss(0, m["atr"] * 0.02)
            self._px[sym] = max(m["atr"], self._px[sym] + drift)

        for p in self._positions:
            sym = p["symbol"]
            m = self._meta[sym]
            p["priceCurrent"] = round(self._px[sym], m["digits"])
            move = p["priceCurrent"] - p["priceOpen"]
            if p["type"] == 1:
                move = -move
            p["profit"] = round(move * p["volume"] * m["mppl"], 2)

        # a take profit that gets hit becomes a closed deal, so the trade
        # log and the closed-PnL series have something real in them
        still_open = []
        for p in self._positions:
            hit = False
            if p["tp"]:
                if p["type"] == 0 and p["priceCurrent"] >= p["tp"]:
                    hit = True
                if p["type"] == 1 and p["priceCurrent"] <= p["tp"]:
                    hit = True
            if hit:
                self._balance += p["profit"]
                self._deals.append(
                    {
                        "dealId": self._next_deal,
                        "positionId": p["ticket"],
                        "symbol": p["symbol"],
                        "type": 1 if p["type"] == 0 else 0,
                        "entry": 1,  # DEAL_ENTRY_OUT
                        "volume": p["volume"],
                        "price": p["priceCurrent"],
                        "profit": p["profit"],
                        "swap": 0.0,
                        "commission": 0.0,
                        "magic": p["magic"],
                        "comment": p["comment"],
                        "time": int(time.time()),
                    }
                )
                self._next_deal += 1
            else:
                still_open.append(p)
        self._positions = still_open

    def account(self) -> dict[str, Any]:
        self._step_prices()
        floating = round(sum(p["profit"] for p in self._positions), 2)
        equity = round(self._balance + floating, 2)
        margin = round(sum(p["volume"] for p in self._positions) * 220.0, 2)
        free = round(max(0.0, equity - margin), 2)
        return {
            "login": 1234567,
            "server": "Demo-Server",
            "currency": "USD",
            "balance": round(self._balance, 2),
            "equity": equity,
            "profit": floating,
            "margin": margin,
            "freeMargin": free,
            "marginLevel": round((equity / margin * 100.0) if margin else 0.0, 2),
            "leverage": 500,
            "name": "KrishMix Demo",
            "company": "Synthetic",
        }

    def positions(self) -> list[dict[str, Any]]:
        self._step_prices()
        return [dict(p) for p in self._positions]

    def deals_since(self, ts: int) -> list[dict[str, Any]]:
        return [dict(d) for d in self._deals if d["time"] >= ts]

    def terminal(self) -> dict[str, Any]:
        return {
            "connected": True,
            "tradeAllowed": True,
            "dataPath": "",  # no real folder; telemetry comes from the fixture dir
            "company": "Synthetic",
            "name": "KrishMix Demo Terminal",
            "build": 0,
        }


# ---------------------------------------------------------------------
def build_source(cfg) -> MarketSource:
    """Pick the real terminal when we can reach it, otherwise fall back to
    the demo book and say so plainly rather than showing an empty page."""
    if getattr(cfg, "force_demo", False):
        print("[source] force_demo is on: using the synthetic demo book")
        return DemoSource(magic_base=cfg.magic_base)

    real = Mt5Source(getattr(cfg, "mt5_path", "") or "")
    if real.connect():
        info = real.terminal()
        print(
            f"[source] connected to MT5 build {info.get('build')} "
            f"({info.get('company')}), data path: {info.get('dataPath')}"
        )
        return real

    print(f"[source] {real.last_error}")
    print("[source] falling back to the synthetic demo book")
    return DemoSource(magic_base=cfg.magic_base)
