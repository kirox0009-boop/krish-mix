"""
Works out WHICH EA and WHICH STRATEGY is behind a given order.

Nothing had to be added to the EAs for this. Every order the suite sends
already carries two independent pieces of provenance:

  MAGIC NUMBER   magic = base + eaSlot*10 + (buy ? 1 : 2)
                 -> which EA opened it, and in which direction

  COMMENT        tag + "|" + note, written by CKMExec.Open
                 KM1|PLAYBOOK|s62|TREND-UP    trigger, score, regime at entry
                 KM1|INSIDEBAR|s-41|RANGE
                 KM2|L3|exh|p42               grid level, exhaustion, pressure
                 KM3|R1|dd450|s-68            recovery leg, drawdown, score
                 KM5|ENTRY|s61
                 KM5|ASSIST|XAUUSD|s61        which symbol it is rescuing

The magic is authoritative and always present. The comment is richer but
brokers truncate it (MT5 allows 31 characters) and some replace it
outright on a partial fill, so every field parsed from it is optional and
the magic is the fallback.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

EA_SLOT_NAMES = {
    1: "EA1 Entry",
    2: "EA2 Grid",
    3: "EA3 Hedge",
    4: "EA4 Basket",
    5: "EA5 Portfolio",
    6: "EA6 TfSelect",
}

EA_SLOT_TAGS = {1: "KM1", 2: "KM2", 3: "KM3", 4: "KM4", 5: "KM5", 6: "KM6"}

#: Human labels for what each strategy token means, used by the UI.
STRATEGY_LABELS = {
    "PULLBACK": "Pullback continuation",
    "BREAKOUT": "Donchian breakout",
    "REVERSAL": "Exhaustion reversal",
    "INSIDEBAR": "Inside bar at swing extreme",
    "FIBREV": "Trend-based fib reversal",
    "PLAYBOOK": "Top-down playbook edge",
    "GRID": "Grid averaging",
    "RECOVERY": "Recovery hedge",
    "ENTRY": "Portfolio entry",
    "ASSIST": "Cross-asset assist",
}

_SCORE_RE = re.compile(r"^s(-?\d+(?:\.\d+)?)$", re.IGNORECASE)
_LEVEL_RE = re.compile(r"^L(\d+)$", re.IGNORECASE)
_PRESS_RE = re.compile(r"^p(-?\d+(?:\.\d+)?)$", re.IGNORECASE)
_LEG_RE = re.compile(r"^R(\d+)$", re.IGNORECASE)
_DD_RE = re.compile(r"^dd(-?\d+(?:\.\d+)?)$", re.IGNORECASE)


@dataclass
class Attribution:
    """Everything we can say about the provenance of one position."""

    ea_slot: int | None = None
    ea_tag: str = ""
    ea_name: str = "unknown"
    side: str = ""  # BUY / SELL, from the magic
    strategy: str = ""  # PULLBACK, INSIDEBAR, GRID, ASSIST, ...
    strategy_label: str = ""
    in_family: bool = False

    # optional, parsed from the comment
    score_at_entry: float | None = None
    regime_at_entry: str = ""
    grid_level: int | None = None
    pressure: float | None = None
    exhaustion: bool | None = None
    recovery_leg: int | None = None
    drawdown_at_entry: float | None = None
    assist_for: str = ""

    raw_comment: str = ""
    raw_magic: int = 0
    parse_note: str = ""

    def to_dict(self) -> dict[str, Any]:
        d = {
            "eaSlot": self.ea_slot,
            "eaTag": self.ea_tag,
            "eaName": self.ea_name,
            "side": self.side,
            "strategy": self.strategy,
            "strategyLabel": self.strategy_label,
            "inFamily": self.in_family,
        }
        # only surface the optional bits when we actually parsed them
        for key, val in (
            ("scoreAtEntry", self.score_at_entry),
            ("regimeAtEntry", self.regime_at_entry),
            ("gridLevel", self.grid_level),
            ("pressure", self.pressure),
            ("exhaustion", self.exhaustion),
            ("recoveryLeg", self.recovery_leg),
            ("drawdownAtEntry", self.drawdown_at_entry),
            ("assistFor", self.assist_for),
        ):
            if val not in (None, ""):
                d[key] = val
        return d


def decode_magic(magic: int, base: int) -> tuple[int | None, str]:
    """Return (ea_slot, side) or (None, "") when the magic is not ours.

    The family occupies base+1 .. base+99, which is how any EA in the
    suite recognises its own orders without a shared registry.
    """
    if not isinstance(magic, int) or magic <= base or magic > base + 99:
        return None, ""
    offset = magic - base
    slot = offset // 10
    dir_code = offset % 10
    if slot < 1 or slot > 9:
        return None, ""
    side = {1: "BUY", 2: "SELL"}.get(dir_code, "")
    return slot, side


def parse_comment(comment: str) -> dict[str, Any]:
    """Pull whatever survives of the note the EA wrote.

    Defensive by design: a truncated or broker-mangled comment yields
    fewer fields rather than an exception.
    """
    out: dict[str, Any] = {}
    if not comment:
        return out

    parts = [p for p in comment.strip().split("|") if p != ""]
    if not parts:
        return out

    # first token is the EA tag when present
    head = parts[0].upper()
    if head in {"KM1", "KM2", "KM3", "KM4", "KM5", "KM6"}:
        out["tag"] = head
        rest = parts[1:]
    else:
        rest = parts

    for tok in rest:
        t = tok.strip()
        if not t:
            continue
        up = t.upper()

        if up in STRATEGY_LABELS and "strategy" not in out:
            out["strategy"] = up
            continue

        m = _LEVEL_RE.match(t)
        if m:
            out["strategy"] = out.get("strategy", "GRID")
            out["gridLevel"] = int(m.group(1))
            continue

        m = _LEG_RE.match(t)
        if m:
            out["strategy"] = out.get("strategy", "RECOVERY")
            out["recoveryLeg"] = int(m.group(1))
            continue

        m = _SCORE_RE.match(t)
        if m:
            out["score"] = float(m.group(1))
            continue

        m = _PRESS_RE.match(t)
        if m:
            out["pressure"] = float(m.group(1))
            continue

        m = _DD_RE.match(t)
        if m:
            out["drawdown"] = float(m.group(1))
            continue

        if up in {"EXH", "EXHAUSTION"}:
            out["exhaustion"] = True
            continue
        if up in {"COOL", "COOLED"}:
            out["exhaustion"] = False
            continue

        # KM5 assist records the symbol it is rescuing, and that token has
        # to be claimed BEFORE the regime pattern below - a symbol like
        # XAUUSD is all upper case and would otherwise be mistaken for a
        # regime name.
        if (
            out.get("strategy") == "ASSIST"
            and "assistFor" not in out
            and re.fullmatch(r"[A-Za-z0-9._#]{3,20}", t)
        ):
            out["assistFor"] = t
            continue

        # a regime name, e.g. TREND-UP / BREAKOUT-DN / RANGE
        if re.fullmatch(r"[A-Z]+(?:-[A-Z]+)?", up) and up not in STRATEGY_LABELS:
            if "regime" not in out and up not in {"BUY", "SELL"}:
                out["regime"] = up
                continue

    return out


def attribute(magic: int, comment: str, base: int) -> Attribution:
    """Combine the two sources of provenance into one answer."""
    a = Attribution(raw_comment=comment or "", raw_magic=int(magic or 0))

    slot, side = decode_magic(a.raw_magic, base)
    if slot is not None:
        a.in_family = True
        a.ea_slot = slot
        a.ea_tag = EA_SLOT_TAGS.get(slot, f"KM{slot}")
        a.ea_name = EA_SLOT_NAMES.get(slot, f"EA{slot}")
        a.side = side

    parsed = parse_comment(a.raw_comment)

    # the comment's tag should agree with the magic; if it does not, trust
    # the magic and say so, because a mismatch means the comment was
    # rewritten by something outside the suite
    tag = parsed.get("tag", "")
    if tag and a.ea_tag and tag != a.ea_tag:
        a.parse_note = f"comment says {tag} but magic says {a.ea_tag}"
    elif tag and not a.ea_tag:
        a.ea_tag = tag
        a.ea_name = EA_SLOT_NAMES.get(
            int(tag[2]) if tag[2:].isdigit() else 0, "unknown"
        )

    a.strategy = parsed.get("strategy", "")
    if not a.strategy and a.ea_slot is not None:
        # no usable comment: fall back to what the EA slot implies
        a.strategy = {2: "GRID", 3: "RECOVERY", 5: "ENTRY"}.get(a.ea_slot, "")
        if a.strategy:
            a.parse_note = a.parse_note or "strategy inferred from the magic"

    a.strategy_label = STRATEGY_LABELS.get(a.strategy, a.strategy or "unattributed")

    a.score_at_entry = parsed.get("score")
    a.regime_at_entry = parsed.get("regime", "")
    a.grid_level = parsed.get("gridLevel")
    a.pressure = parsed.get("pressure")
    a.exhaustion = parsed.get("exhaustion")
    a.recovery_leg = parsed.get("recoveryLeg")
    a.drawdown_at_entry = parsed.get("drawdown")
    a.assist_for = parsed.get("assistFor", "")

    return a
