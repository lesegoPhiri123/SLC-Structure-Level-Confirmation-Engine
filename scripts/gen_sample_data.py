#!/usr/bin/env python3
"""Regenerates data/sample_state.json: a plausible SLC state snapshot
(downtrend HTF, a supply zone, a confirmed short) so `make web` has
something to render without a running MT5 terminal.
"""
import json
import random
import time
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "data" / "sample_state.json"
BAR_SECONDS = 5 * 60
N_CANDLES = 180

random.seed(7)


def build_candles():
    candles = []
    now = int(time.time())
    start_time = now - N_CANDLES * BAR_SECONDS
    price = 1.10500

    # Downtrend drift with one sharp expansion leg to seed the supply zone.
    for i in range(N_CANDLES):
        t = start_time + i * BAR_SECONDS
        drift = -0.00004
        if 60 <= i <= 64:
            drift = -0.00060  # expansion leg
        noise = random.uniform(-0.00012, 0.00012)
        open_ = price
        close = price + drift + noise
        high = max(open_, close) + random.uniform(0, 0.00015)
        low = min(open_, close) - random.uniform(0, 0.00015)
        candles.append({"t": t, "o": round(open_, 5), "h": round(high, 5),
                         "l": round(low, 5), "c": round(close, 5)})
        price = close

    return candles


def main():
    candles = build_candles()
    base = candles[59]  # last bullish candle before the expansion leg at i=60..64
    zone_low, zone_high = min(base["o"], base["c"]), max(base["o"], base["c"])
    zone_time = base["t"]

    touch_candle = candles[140]

    state = {
        "symbol": "EURUSD",
        "htf": "PERIOD_H4",
        "ltf": "PERIOD_M5",
        "htf_state": "DOWNTREND",
        "updated": time.strftime("%Y.%m.%d %H:%M:%S"),
        "candles": candles,
        "zones": [
            {
                "id": 1,
                "type": "supply",
                "low": zone_low,
                "high": zone_high,
                "time": zone_time,
                "status": "traded",
                "touches": 1,
                "flipped": False,
            },
            {
                "id": 2,
                "type": "supply",
                "low": round(zone_low - 0.0015, 5),
                "high": round(zone_high - 0.0015, 5),
                "time": candles[100]["t"],
                "status": "active",
                "touches": 1,
                "flipped": False,
            },
        ],
        "signals": [
            {"time": touch_candle["t"], "dir": "short", "zone_id": 1, "k": 78.4},
        ],
        "trades": [
            {"time": touch_candle["t"], "dir": "short", "entry": touch_candle["c"],
             "sl": round(zone_high + 0.0005, 5),
             "tp": round(touch_candle["c"] - 2 * (zone_high + 0.0005 - touch_candle["c"]), 5),
             "lots": 0.1},
        ],
    }

    OUT.write_text(json.dumps(state, indent=2))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
