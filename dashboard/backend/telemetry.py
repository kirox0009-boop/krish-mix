"""
Reads the JSON snapshots the EAs write.

Each EA drops a document into

    <terminal data folder>\\MQL5\\Files\\KrishMix\\telemetry\\<TAG>_<SYMBOL>.json

and the terminal itself tells us where that folder is, so there is nothing
to configure. Files are written atomically on the MQL5 side, so a partial
read is not a normal failure mode - but a file can still be missing, stale
or malformed, and each of those is reported rather than swallowed.

A stalled feed is worth surfacing: it usually means the EA was removed
from its chart, or the terminal lost the symbol.
"""

from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

FILE_RE = re.compile(r"^(KM[1-6])_(.+)\.json$", re.IGNORECASE)


@dataclass
class Snapshot:
    """One EA's document, plus how fresh it is."""

    ea: str
    symbol: str
    path: str
    data: dict[str, Any]
    mtime: float
    age_seconds: float
    stale: bool
    error: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "ea": self.ea,
            "symbol": self.symbol,
            "ageSeconds": round(self.age_seconds, 1),
            "stale": self.stale,
            "error": self.error,
            "data": self.data,
        }


class TelemetryReader:
    def __init__(self, stale_seconds: int = 90) -> None:
        self.stale_seconds = max(5, stale_seconds)
        self._dir: Path | None = None
        self.last_error = ""
        #: keeps the previous good parse so one bad read does not blank the UI
        self._cache: dict[str, Snapshot] = {}

    # -----------------------------------------------------------------
    def set_dir(self, path: Path | str | None) -> None:
        self._dir = Path(path) if path else None

    @property
    def directory(self) -> Path | None:
        return self._dir

    def dir_status(self) -> dict[str, Any]:
        if self._dir is None:
            return {"path": "", "exists": False, "note": "telemetry folder not located yet"}
        exists = self._dir.is_dir()
        return {
            "path": str(self._dir),
            "exists": exists,
            "note": "" if exists else "folder does not exist yet - has any EA written a snapshot?",
        }

    # -----------------------------------------------------------------
    def read_all(self) -> dict[str, Snapshot]:
        """Return {key: Snapshot} keyed by "<EA>_<SYMBOL>"."""
        if self._dir is None or not self._dir.is_dir():
            # keep whatever we had; the folder may appear later
            return dict(self._cache)

        now = time.time()
        found: dict[str, Snapshot] = {}

        try:
            entries = sorted(self._dir.iterdir())
        except OSError as exc:
            self.last_error = f"cannot list {self._dir}: {exc}"
            return dict(self._cache)

        for p in entries:
            if not p.is_file():
                continue
            m = FILE_RE.match(p.name)
            if not m:
                continue  # ignore .tmp files and anything else

            ea, symbol = m.group(1).upper(), m.group(2)
            key = f"{ea}_{symbol}"

            try:
                mtime = p.stat().st_mtime
                text = p.read_text(encoding="utf-8", errors="replace")
                data = json.loads(text)
                if not isinstance(data, dict):
                    raise ValueError("document root is not an object")
                err = ""
            except (OSError, json.JSONDecodeError, ValueError) as exc:
                # A malformed document is nearly always a half-written file
                # that slipped past the atomic move. Hold the last good one
                # rather than flashing an error panel at the operator.
                prev = self._cache.get(key)
                if prev is not None:
                    prev.error = f"last read failed: {exc}"
                    found[key] = prev
                    continue
                found[key] = Snapshot(
                    ea=ea, symbol=symbol, path=str(p), data={},
                    mtime=0.0, age_seconds=1e9, stale=True,
                    error=f"unreadable: {exc}",
                )
                continue

            age = max(0.0, now - mtime)
            found[key] = Snapshot(
                ea=ea,
                symbol=symbol,
                path=str(p),
                data=data,
                mtime=mtime,
                age_seconds=age,
                stale=age > self.stale_seconds,
                error=err,
            )

        self._cache = found
        return dict(found)

    # -----------------------------------------------------------------
    def by_ea(self, snaps: dict[str, Snapshot]) -> dict[str, list[Snapshot]]:
        out: dict[str, list[Snapshot]] = {}
        for s in snaps.values():
            out.setdefault(s.ea, []).append(s)
        for lst in out.values():
            lst.sort(key=lambda s: s.symbol)
        return out

    def symbols(self, snaps: dict[str, Snapshot]) -> list[str]:
        syms = {s.symbol for s in snaps.values() if s.symbol.upper() != "PORTFOLIO"}
        return sorted(syms)

    def health(self, snaps: dict[str, Snapshot]) -> dict[str, Any]:
        total = len(snaps)
        stale = sum(1 for s in snaps.values() if s.stale)
        broken = sum(1 for s in snaps.values() if s.error)
        return {
            "files": total,
            "stale": stale,
            "withErrors": broken,
            "staleAfterSeconds": self.stale_seconds,
            "directory": self.dir_status(),
            "lastError": self.last_error,
        }
