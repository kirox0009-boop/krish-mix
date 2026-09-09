#!/usr/bin/env python3
"""
Single command to start the KrishMix dashboard.

    python run.py                      live terminal if reachable, else demo
    python run.py --demo               force the synthetic book
    python run.py --set-pin 482913     set the developer-mode PIN
    python run.py --host 0.0.0.0       expose beyond loopback (read the warning)

Requires Python 3.9+. The only optional dependency is the MetaTrader5
package, which is Windows only and must run on the same machine as the
terminal:

    pip install MetaTrader5
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from backend.app import main  # noqa: E402

if __name__ == "__main__":
    # 3.9 is enough: the modern annotation syntax is only ever evaluated
    # lazily thanks to `from __future__ import annotations`.
    if sys.version_info < (3, 9):
        sys.exit("Python 3.9 or newer is required")
    sys.exit(main())
