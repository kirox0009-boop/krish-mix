"""
Developer-mode gate.

Normal mode shows what the bot did. Developer mode shows how it decided,
and is what the operator unlocks with a PIN.

Three things matter for a short secret like a PIN:

  1. it is compared in constant time (handled in Config.check_pin)
  2. wrong guesses are RATE LIMITED, per client, with a lockout - a
     6-digit PIN is only 10^6 combinations, so without this it is not a
     secret at all
  3. a successful unlock issues a random token with an expiry, rather
     than the browser holding on to the PIN

The token is handed out as an HttpOnly cookie, so page scripts never see
it and cannot leak it; the UI asks /api/session whether it is unlocked.
"""

from __future__ import annotations

import secrets
import threading
import time
from dataclasses import dataclass, field

TOKEN_COOKIE = "km_dev"


@dataclass
class _Attempts:
    count: int = 0
    first_ts: float = 0.0
    locked_until: float = 0.0


@dataclass
class Session:
    token: str
    created: float
    expires: float
    client: str


class AuthManager:
    """In-memory sessions and per-client rate limiting.

    Sessions live in memory on purpose: restarting the backend re-locks
    developer mode, which is the safer default.
    """

    def __init__(
        self,
        *,
        session_minutes: int = 60,
        max_attempts: int = 5,
        window_seconds: int = 300,
        lockout_seconds: int = 900,
    ) -> None:
        self._sessions: dict[str, Session] = {}
        self._attempts: dict[str, _Attempts] = {}
        self._lock = threading.Lock()

        self.session_seconds = max(60, session_minutes * 60)
        self.max_attempts = max(1, max_attempts)
        self.window_seconds = max(10, window_seconds)
        self.lockout_seconds = max(10, lockout_seconds)

    # --- rate limiting ----------------------------------------------
    def lockout_remaining(self, client: str) -> int:
        """Seconds this client must wait, or 0 when it may try."""
        now = time.time()
        with self._lock:
            rec = self._attempts.get(client)
            if rec is None:
                return 0
            if rec.locked_until > now:
                return int(rec.locked_until - now) + 1
            # window elapsed: forget the old failures
            if rec.first_ts and (now - rec.first_ts) > self.window_seconds:
                self._attempts.pop(client, None)
            return 0

    def record_failure(self, client: str) -> int:
        """Count a bad guess. Returns the lockout in seconds if this one
        tripped the limit, else 0."""
        now = time.time()
        with self._lock:
            rec = self._attempts.setdefault(client, _Attempts())
            if not rec.first_ts or (now - rec.first_ts) > self.window_seconds:
                rec.count = 0
                rec.first_ts = now
            rec.count += 1
            if rec.count >= self.max_attempts:
                rec.locked_until = now + self.lockout_seconds
                rec.count = 0
                rec.first_ts = now
                return self.lockout_seconds
            return 0

    def attempts_left(self, client: str) -> int:
        with self._lock:
            rec = self._attempts.get(client)
            if rec is None:
                return self.max_attempts
            return max(0, self.max_attempts - rec.count)

    def clear_failures(self, client: str) -> None:
        with self._lock:
            self._attempts.pop(client, None)

    # --- sessions ----------------------------------------------------
    def issue(self, client: str) -> Session:
        now = time.time()
        token = secrets.token_urlsafe(32)
        sess = Session(
            token=token,
            created=now,
            expires=now + self.session_seconds,
            client=client,
        )
        with self._lock:
            self._sessions[token] = sess
            self._prune(now)
        return sess

    def validate(self, token: str | None) -> Session | None:
        if not token:
            return None
        now = time.time()
        with self._lock:
            sess = self._sessions.get(token)
            if sess is None:
                return None
            if sess.expires <= now:
                self._sessions.pop(token, None)
                return None
            return sess

    def revoke(self, token: str | None) -> bool:
        if not token:
            return False
        with self._lock:
            return self._sessions.pop(token, None) is not None

    def revoke_all(self) -> int:
        with self._lock:
            n = len(self._sessions)
            self._sessions.clear()
            return n

    def _prune(self, now: float) -> None:
        dead = [t for t, s in self._sessions.items() if s.expires <= now]
        for t in dead:
            self._sessions.pop(t, None)

    def active_count(self) -> int:
        now = time.time()
        with self._lock:
            self._prune(now)
            return len(self._sessions)

    def session_info(self, token: str | None) -> dict:
        sess = self.validate(token)
        if sess is None:
            return {"developer": False, "expiresIn": 0}
        return {
            "developer": True,
            "expiresIn": int(sess.expires - time.time()),
            "since": int(sess.created),
        }
