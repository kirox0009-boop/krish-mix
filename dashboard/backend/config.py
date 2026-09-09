"""
Configuration and PIN storage for the KrishMix dashboard.

The PIN that unlocks developer mode is NEVER stored. Only a salted
PBKDF2-HMAC-SHA256 hash of it is written to disk, so reading config.json
does not reveal the PIN. Standard library only.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path
from typing import Any

#: PBKDF2 cost. High enough to make a 6-digit brute force expensive on the
#: server side, low enough that an unlock request still feels instant.
PIN_ITERATIONS = 240_000
PIN_MIN_LENGTH = 4


@dataclass
class Config:
    # --- where the dashboard listens ---------------------------------
    #: Bind to loopback by default. A PIN over plain HTTP is weak, so the
    #: safe default is "reachable only from this machine" and the operator
    #: opts in to exposing it.
    host: str = "127.0.0.1"
    port: int = 8734

    # --- suite wiring ------------------------------------------------
    #: Must match InpMagicBase in every EA. Used to decode which EA and
    #: which direction a position came from.
    magic_base: int = 51000

    # --- polling and persistence ------------------------------------
    poll_seconds: int = 2
    sample_seconds: int = 15
    retention_days: int = 45
    db_path: str = "krishmix_dashboard.sqlite3"

    #: Optional override. Normally left empty: the terminal tells us where
    #: its data folder is, so telemetry is found with no configuration.
    telemetry_dir: str = ""

    #: Treat a telemetry file older than this as a stalled feed.
    telemetry_stale_seconds: int = 90

    # --- MT5 connection ---------------------------------------------
    #: Leave blank to attach to whichever terminal is already running.
    mt5_path: str = ""
    #: Force the synthetic demo source, for looking at the dashboard
    #: before it is pointed at a live terminal.
    force_demo: bool = False

    # --- developer mode ---------------------------------------------
    pin_salt: str = ""
    pin_hash: str = ""
    pin_iterations: int = PIN_ITERATIONS
    #: How long an unlocked session lasts before it re-locks itself.
    session_minutes: int = 60
    #: Brute-force protection on the unlock endpoint.
    unlock_max_attempts: int = 5
    unlock_window_seconds: int = 300
    unlock_lockout_seconds: int = 900

    # --- privacy ----------------------------------------------------
    #: Normal mode hides the strategy internals. Developer mode reveals
    #: them. This flag only affects whether normal mode ALSO hides money.
    hide_money_in_normal: bool = False

    _path: str = field(default="", repr=False, compare=False)

    # ----------------------------------------------------------------
    @classmethod
    def load(cls, path: str | os.PathLike[str]) -> "Config":
        p = Path(path)
        cfg = cls()
        cfg._path = str(p)

        if p.exists():
            try:
                raw = json.loads(p.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError) as exc:
                raise SystemExit(f"config {p} is not readable JSON: {exc}") from exc

            known = {f.name for f in fields(cls) if not f.name.startswith("_")}
            unknown = sorted(set(raw) - known)
            if unknown:
                print(f"[config] ignoring unknown key(s): {', '.join(unknown)}")
            for k, v in raw.items():
                if k in known:
                    setattr(cfg, k, v)

        return cfg

    def save(self) -> None:
        if not self._path:
            return
        p = Path(self._path)
        p.parent.mkdir(parents=True, exist_ok=True)

        data = {k: v for k, v in asdict(self).items() if not k.startswith("_")}
        # atomic-ish: write beside the target then replace
        tmp = p.with_suffix(p.suffix + ".tmp")
        tmp.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
        os.replace(tmp, p)

    # --- PIN handling ------------------------------------------------
    @property
    def has_pin(self) -> bool:
        return bool(self.pin_salt and self.pin_hash)

    def _derive(self, pin: str, salt_hex: str, iterations: int) -> str:
        return hashlib.pbkdf2_hmac(
            "sha256",
            pin.encode("utf-8"),
            bytes.fromhex(salt_hex),
            iterations,
        ).hex()

    def set_pin(self, pin: str) -> None:
        """Store a new PIN as a fresh salt plus hash. The PIN itself is
        discarded immediately and never written anywhere."""
        pin = pin.strip()
        if len(pin) < PIN_MIN_LENGTH:
            raise ValueError(f"PIN must be at least {PIN_MIN_LENGTH} characters")

        salt = secrets.token_bytes(16)
        self.pin_salt = salt.hex()
        self.pin_iterations = PIN_ITERATIONS
        self.pin_hash = self._derive(pin, self.pin_salt, self.pin_iterations)

    def check_pin(self, pin: str) -> bool:
        """Constant-time comparison, so response timing does not leak how
        much of a guess was correct."""
        if not self.has_pin:
            return False
        try:
            candidate = self._derive(pin, self.pin_salt, self.pin_iterations)
        except ValueError:
            return False
        return secrets.compare_digest(candidate, self.pin_hash)

    def ensure_pin(self) -> str | None:
        """Generate a PIN on first run and return it once so the caller can
        show it. Returns None when a PIN already exists."""
        if self.has_pin:
            return None
        pin = f"{secrets.randbelow(1_000_000):06d}"
        self.set_pin(pin)
        self.save()
        return pin

    # --- convenience -------------------------------------------------
    def public_dict(self) -> dict[str, Any]:
        """Settings that are safe to hand to the browser. Deliberately
        excludes the PIN material and the filesystem paths."""
        return {
            "magicBase": self.magic_base,
            "pollSeconds": self.poll_seconds,
            "sampleSeconds": self.sample_seconds,
            "retentionDays": self.retention_days,
            "sessionMinutes": self.session_minutes,
            "hideMoneyInNormal": self.hide_money_in_normal,
        }
