"""
Normal mode versus developer mode.

The EAs export full fidelity on purpose, so the decision about what a
viewer may see is made here, in one place, next to the authentication.

  NORMAL MODE      what the bot is DOING.
                   Live trades with the strategy that opened each one,
                   money, equity / PnL / drawdown curves, which EAs are
                   alive, per-symbol portfolio state, basket targets.

  DEVELOPER MODE   how it DECIDED.
                   Composite scores, every indicator value, the per-layer
                   qualified counts, the block histogram, all thresholds
                   and config, the grid and hedge sizing workings, and the
                   playbook narrative verbatim.

The split is deliberately drawn at "outcome" versus "reasoning". Anyone
looking over a shoulder can see the account is up and that an inside-bar
short is running; they cannot see how many layers agreed, what the score
was, or where the thresholds sit.

IMPLEMENTED AS AN ALLOW-LIST. A field that nobody has explicitly cleared
for normal mode is hidden, so adding telemetry later cannot accidentally
start leaking. Developer mode passes documents through untouched.
"""

from __future__ import annotations

from typing import Any

#: Marker meaning "include this value as it is".
KEEP = True
#: Marker meaning "include every element / key, shaped by the given spec".
ANY = "*"


def pick(data: Any, spec: Any) -> Any:
    """Copy only what the spec allows.

    spec is either KEEP, or a dict of {key: spec}. A dict spec containing
    the ANY key applies that sub-spec to every element of a list or every
    value of an object.
    """
    if spec is KEEP:
        return data

    if isinstance(spec, dict):
        if isinstance(data, list):
            sub = spec.get(ANY, KEEP)
            return [pick(item, sub) for item in data]

        if isinstance(data, dict):
            out: dict[str, Any] = {}
            if ANY in spec:
                sub = spec[ANY]
                for k, v in data.items():
                    out[k] = pick(v, sub)
                return out
            for key, sub in spec.items():
                if key in data:
                    out[key] = pick(data[key], sub)
            return out

        # spec expects structure but the data is scalar or missing
        return None

    return None


# ---------------------------------------------------------------------
# Normal-mode allow-lists, one per telemetry document type.
# ---------------------------------------------------------------------

_HEADER = {"ea": KEEP, "symbol": KEEP, "ts": KEEP, "time": KEEP, "suiteVer": KEEP}

_MARKET = {"market": {"bid": KEEP, "ask": KEEP, "spreadPts": KEEP, "digits": KEEP}}

_ROSTER = {"roster": {ANY: {"slot": KEEP, "name": KEEP, "alive": KEEP}}}

_TELEM_HEALTH = {"telemetry": {"writes": KEEP, "failures": KEEP, "lastError": KEEP}}

#: KM1. The strategy that fired and how many trades it produced are
#: outcomes, so they stay. "qualified" is a vote count - how many times a
#: layer said yes - and that is exactly the number to withhold.
SPEC_KM1 = {
    **_HEADER,
    **_MARKET,
    **_ROSTER,
    **_TELEM_HEALTH,
    "view": {"regime": KEEP, "vol": KEEP, "atr": KEEP},
    "gate": {"entries": KEEP, "lastTrigger": KEEP, "lastEntryTs": KEEP},
    "layers": {ANY: {"name": KEEP, "entered": KEEP, "enabled": KEEP}},
    "structure": {"trend": {"dir": KEEP}},
    "insideBar": {"enabled": KEEP, "timeframe": KEEP, "found": KEEP},
    "fib": {"enabled": KEEP, "valid": KEEP},
    "playbook": {"enabled": KEEP, "ready": KEEP, "valid": KEEP, "dir": KEEP},
    "holdings": {
        ANY: {"count": KEEP, "lots": KEEP, "profit": KEEP, "avgPrice": KEEP}
    },
}

#: KM2. Whether the grid is holding back is a state worth showing; the
#: distance, pressure and next lot are the mechanism, so they are not.
SPEC_KM2 = {
    **_HEADER,
    **_MARKET,
    **_ROSTER,
    **_TELEM_HEALTH,
    "view": {"regime": KEEP, "vol": KEEP},
    "sides": {
        ANY: {
            "side": KEEP,
            "basket": {"legs": KEEP, "lots": KEEP, "profit": KEEP, "avgPrice": KEEP},
            "plan": {"wouldAdd": KEEP, "level": KEEP},
            "addsMade": KEEP,
        }
    },
}

#: KM3. That a recovery is armed or running is visible; the lock versus
#: recovery split and the conviction thresholds are not.
SPEC_KM3 = {
    **_HEADER,
    **_MARKET,
    **_ROSTER,
    **_TELEM_HEALTH,
    "view": {"regime": KEEP, "vol": KEEP},
    "baskets": {ANY: {"legs": KEEP, "lots": KEEP, "profit": KEEP, "avgPrice": KEEP}},
    "recoveryLegs": {
        "buyCount": KEEP, "buyLots": KEEP,
        "sellCount": KEEP, "sellLots": KEEP, "profit": KEEP,
    },
    "plan": {"wouldFire": KEEP, "losingSide": KEEP, "drawdown": KEEP},
    "history": {"legsFired": KEEP, "lastFiredTs": KEEP},
}

#: KM4. The target NUMBER is what a trader watches, so it stays. The
#: "workings" string spells out base x factor x relief and is withheld.
SPEC_KM4 = {
    **_HEADER,
    **_MARKET,
    **_ROSTER,
    **_TELEM_HEALTH,
    "view": {"regime": KEEP, "vol": KEEP},
    "groups": {
        ANY: {
            "name": KEEP, "legs": KEEP, "lots": KEEP, "profit": KEEP,
            "target": KEEP, "ridingOwnTp": KEEP, "gridOpen": KEEP,
        }
    },
    "history": {"closes": KEEP, "lastAction": KEEP},
}

#: KM5. The portfolio picture and which symbol is stuck are the whole
#: point of the view. The assist thresholds and per-symbol scores are the
#: mechanism.
SPEC_KM5 = {
    **_HEADER,
    **_TELEM_HEALTH,
    "portfolio": {
        "symbolsHolding": KEEP, "legs": KEEP, "lots": KEEP, "profit": KEEP,
        "drawdown": KEEP, "target": KEEP, "assistLegs": KEEP,
        "assistLots": KEEP, "anyGrid": KEEP, "anyHedge": KEEP,
        "ridingOwnTp": KEEP,
        "stuck": {"symbol": KEEP, "drawdown": KEEP, "legs": KEEP, "lots": KEEP,
                  "losingSide": KEEP},
    },
    "symbols": {
        ANY: {
            "symbol": KEEP, "tradable": KEEP, "isStuck": KEEP,
            "legs": KEEP, "buyLegs": KEEP, "sellLegs": KEEP,
            "lots": KEEP, "profit": KEEP, "drawdown": KEEP,
            "gridOpen": KEEP, "hedgeOpen": KEEP,
            "assistLegs": KEEP, "assistLots": KEEP,
            "suiteEa1Live": KEEP,
            "view": {"regime": KEEP, "vol": KEEP},
        }
    },
    "assist": {"count": KEEP, "lastTs": KEEP},
    "activity": {"entries": KEEP, "assists": KEEP, "closes": KEEP, "lastAction": KEEP},
}

#: KM6. The chosen style and timeframe are operational facts. The three
#: competing scores and the spread-economics reasoning are not.
SPEC_KM6 = {
    **_HEADER,
    **_TELEM_HEALTH,
    "symbols": {
        ANY: {
            "symbol": KEEP, "ready": KEEP, "valid": KEEP,
            "style": KEEP, "timeframe": KEEP, "liquidSession": KEEP,
        }
    },
}

SPECS = {
    "KM1": SPEC_KM1,
    "KM2": SPEC_KM2,
    "KM3": SPEC_KM3,
    "KM4": SPEC_KM4,
    "KM5": SPEC_KM5,
    "KM6": SPEC_KM6,
}

#: Fields on a live position that only developer mode sees. The strategy
#: name itself is NOT here: knowing an inside-bar short is running is the
#: kind of thing the operator asked to be able to see.
POSITION_DEV_ONLY = (
    "scoreAtEntry", "regimeAtEntry", "pressure", "exhaustion",
    "drawdownAtEntry", "rawComment", "magic", "parseNote",
)

#: Account fields hidden when hide_money_in_normal is switched on.
ACCOUNT_MONEY_FIELDS = (
    "balance", "equity", "profit", "margin", "freeMargin", "marginLevel",
)

#: Keys that must never appear in a normal-mode response. Used by the
#: self-check below, which is what stops a future edit from quietly
#: widening the allow-list.
FORBIDDEN_IN_NORMAL = (
    "score", "scoreBest", "adxBest", "blocks", "floors", "config",
    "qualified", "narrative", "confidence", "confluences", "workings",
    "reason", "pressure", "needed", "travelled", "nextLot",
    "lockLot", "recoveryLot", "rsi", "stoch", "macdHist", "macdSlope",
    "bbPercent", "bbWidth", "plusDI", "minusDI", "emaFast", "emaSlow",
    "emaFilter", "bbUpper", "bbLower", "mtfAgree", "bullExhaust",
    "bearExhaust", "maturity", "extensionAtr", "retracePct", "levels",
    "scalpScore", "intradayScore", "swingScore", "spreadCost",
    "moneyPerLot", "assistTravel", "triggerDd", "coverage", "horizonAtr",
    "maxOvershoot", "minScore", "minAdx", "status", "summary",
)


class Redactor:
    def __init__(self, *, hide_money_in_normal: bool = False) -> None:
        self.hide_money_in_normal = hide_money_in_normal

    # -----------------------------------------------------------------
    def telemetry_doc(self, ea: str, data: dict, developer: bool) -> dict:
        if developer:
            return data
        spec = SPECS.get(ea.upper())
        if spec is None:
            # an unrecognised document is withheld entirely rather than
            # guessed at
            return {"ea": ea, "redacted": True, "note": "no normal-mode view defined"}
        out = pick(data, spec)
        if not isinstance(out, dict):
            return {"ea": ea, "redacted": True}
        out["redacted"] = True
        if not self.hide_money_in_normal and "account" in data:
            out["account"] = data["account"]
        return out

    def account(self, acct: dict, developer: bool) -> dict:
        if developer or not self.hide_money_in_normal:
            return acct
        return {k: v for k, v in acct.items() if k not in ACCOUNT_MONEY_FIELDS}

    def position(self, pos: dict, developer: bool) -> dict:
        if developer:
            return pos
        return {k: v for k, v in pos.items() if k not in POSITION_DEV_ONLY}

    def positions(self, rows: list[dict], developer: bool) -> list[dict]:
        return [self.position(p, developer) for p in rows]

    # -----------------------------------------------------------------
    def self_check(self) -> list[str]:
        """Prove the allow-lists cannot emit anything on the forbidden
        list. Run at start-up so a mistake fails loudly instead of leaking
        quietly."""
        problems: list[str] = []

        def walk(spec: Any, path: str) -> None:
            if not isinstance(spec, dict):
                return
            for key, sub in spec.items():
                if key == ANY:
                    walk(sub, f"{path}[]")
                    continue
                if key in FORBIDDEN_IN_NORMAL:
                    problems.append(f"{path}.{key} is allowed but is marked developer-only")
                walk(sub, f"{path}.{key}")

        for ea, spec in SPECS.items():
            walk(spec, ea)
        return problems
