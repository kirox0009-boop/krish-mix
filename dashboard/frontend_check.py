#!/usr/bin/env python3
"""
Static checks for the no-build frontend.

Node is unavailable in this sandbox, so instead of running a JS engine this
verifies the things that actually break a no-build ES-module frontend:

  - balanced braces / parens / brackets outside strings and comments
  - every import resolves to a file that exists
  - every named import is actually exported by that module
  - every getElementById in the JS has a matching id in the HTML
  - every id referenced from the HTML side is used
  - CSS braces balance and every class used in JS/HTML is defined (reported,
    not enforced, since some are conditional)
  - the backend really serves each asset with the right content type
"""

from __future__ import annotations

import json
import re
import sys
import threading
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
FE = HERE / "frontend"
sys.path.insert(0, str(HERE))

FAIL: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + (f"  {detail}" if detail else ""))
    if not ok:
        FAIL.append(label)


def strip_js(src: str) -> str:
    """Remove comments, strings and template literals, keeping newlines."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and nxt == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
            continue
        if c in "\"'`":
            quote = c
            i += 1
            while i < n and src[i] != quote:
                if src[i] == "\\":
                    i += 1
                elif src[i] == "\n":
                    out.append("\n")
                i += 1
            i += 1
            out.append('""')
            continue
        out.append(c)
        i += 1
    return "".join(out)


def balance(text: str, name: str) -> bool:
    pairs = {"{": "}", "(": ")", "[": "]"}
    closing = {v: k for k, v in pairs.items()}
    stack = []
    line = 1
    for ch in text:
        if ch == "\n":
            line += 1
        elif ch in pairs:
            stack.append((ch, line))
        elif ch in closing:
            if not stack or stack[-1][0] != closing[ch]:
                print(f"        {name}: unexpected '{ch}' at line {line}")
                return False
            stack.pop()
    if stack:
        print(f"        {name}: unclosed '{stack[-1][0]}' from line {stack[-1][1]}")
        return False
    return True


def main() -> int:
    js_files = sorted(FE.glob("js/*.js"))
    print(f"=== frontend files ===")
    for p in sorted(FE.rglob("*")):
        if p.is_file():
            print(f"  {p.relative_to(FE)}  ({p.stat().st_size} bytes)")

    print("\n=== JS syntax balance ===")
    stripped: dict[str, str] = {}
    for p in js_files:
        raw = p.read_text(encoding="utf-8")
        s = strip_js(raw)
        stripped[p.name] = s
        check(f"{p.name} balanced", balance(s, p.name))

    print("\n=== module graph ===")
    exports: dict[str, set[str]] = {}
    for p in js_files:
        s = stripped[p.name]
        names: set[str] = set()
        for m in re.finditer(r"export\s+(?:async\s+)?function\s+(\w+)", s):
            names.add(m.group(1))
        for m in re.finditer(r"export\s+(?:const|let|var|class)\s+(\w+)", s):
            names.add(m.group(1))
        for m in re.finditer(r"export\s*\{([^}]*)\}", s):
            for part in m.group(1).split(","):
                part = part.strip()
                if part:
                    names.add(part.split(" as ")[-1].strip())
        exports[p.name] = names
        print(f"  {p.name} exports: {sorted(names) or '(none)'}")

    ok_graph = True
    for p in js_files:
        s = stripped[p.name]
        for m in re.finditer(r"import\s*\{([^}]*)\}\s*from\s*\"\"", s):
            pass  # strings were blanked; re-scan the raw text instead
        raw = p.read_text(encoding="utf-8")
        for m in re.finditer(
            r"import\s*\{([^}]*)\}\s*from\s*['\"]([^'\"]+)['\"]", raw
        ):
            wanted = [x.strip().split(" as ")[0].strip()
                      for x in m.group(1).split(",") if x.strip()]
            target = m.group(2)
            tp = (p.parent / target).resolve()
            if not tp.is_file():
                print(f"        {p.name}: import target missing -> {target}")
                ok_graph = False
                continue
            have = exports.get(tp.name, set())
            missing = [w for w in wanted if w not in have]
            if missing:
                print(f"        {p.name}: {tp.name} does not export {missing}")
                ok_graph = False
    check("every import resolves and is exported", ok_graph)

    print("\n=== HTML ids vs getElementById ===")
    html = (FE / "index.html").read_text(encoding="utf-8")
    html_ids = set(re.findall(r'\bid="([^"]+)"', html))
    js_all = "\n".join(p.read_text(encoding="utf-8") for p in js_files)
    used_ids = set(re.findall(r"\$\('([^']+)'\)", js_all))
    used_ids |= set(re.findall(r"getElementById\(['\"]([^'\"]+)['\"]\)", js_all))
    missing = sorted(used_ids - html_ids)
    check("all ids referenced from JS exist in the HTML", not missing, str(missing))
    unused = sorted(html_ids - used_ids)
    print(f"        ids in HTML not referenced from JS: {unused or 'none'}")

    print("\n=== CSS ===")
    css = (FE / "css" / "app.css").read_text(encoding="utf-8")
    css_nc = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    check("app.css braces balance", css_nc.count("{") == css_nc.count("}"),
          f"{css_nc.count('{')} open / {css_nc.count('}')} close")
    defined = set(re.findall(r"\.([a-zA-Z][\w-]*)", css_nc))
    used_cls = set()
    for m in re.finditer(r"""(?:class=["']|el\(\s*['"][\w]+['"]\s*,\s*['"])([^"']+)""",
                         html + js_all):
        for c in m.group(1).replace("$", " ").split():
            if re.fullmatch(r"[a-zA-Z][\w-]*", c):
                used_cls.add(c)
    undef = sorted(c for c in used_cls - defined if not c.startswith("km"))
    print(f"        classes used but not in the stylesheet: {undef or 'none'}")

    print("\n=== served by the backend with correct content types ===")
    from backend.auth import AuthManager
    from backend.config import Config
    from backend.mt5source import DemoSource
    from backend.poller import Poller
    from backend.redact import Redactor
    from backend.server import Context, make_server
    from backend.store import Store
    from backend.telemetry import TelemetryReader

    tmp = HERE / ".fecheck"
    tmp.mkdir(exist_ok=True)
    cfg = Config.load(tmp / "cfg.json")
    cfg.db_path = str(tmp / "t.sqlite3")
    cfg.ensure_pin()
    src = DemoSource()
    src.connect()
    store = Store(cfg.db_path)
    tel = TelemetryReader()
    poller = Poller(source=src, store=store, telemetry=tel,
                    magic_base=51000, poll_seconds=1, sample_seconds=1)
    poller.start()
    ctx = Context(cfg=cfg, auth=AuthManager(), redactor=Redactor(),
                  poller=poller, store=store, frontend_dir=FE)
    httpd = make_server(ctx, "127.0.0.1", 0)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever,
                     kwargs={"poll_interval": 0.2}, daemon=True).start()

    expect = [
        ("/", "text/html"),
        ("/css/app.css", "text/css"),
        ("/js/app.js", "text/javascript"),
        ("/js/api.js", "text/javascript"),
        ("/js/fmt.js", "text/javascript"),
        ("/js/charts.js", "text/javascript"),
        ("/js/views.js", "text/javascript"),
    ]
    for path, ctype in expect:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=8) as r:
                got = r.headers.get("Content-Type", "")
                body = r.read()
            check(f"GET {path}", r.status == 200 and ctype in got and len(body) > 0,
                  f"{len(body)}B {got}")
        except Exception as exc:
            check(f"GET {path}", False, str(exc))

    httpd.shutdown()
    poller.stop()
    store.close()
    httpd.server_close()

    print("\n" + "=" * 62)
    if FAIL:
        print(f"FAILED ({len(FAIL)}): " + ", ".join(FAIL))
        return 1
    print("ALL FRONTEND CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
