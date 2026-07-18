# SLC-Structure-Level-Confirmation-Engine

SLC (Structure, Level, Confirmation) Engine — an MT5 Expert Advisor that trades HTF-aligned
LTF supply/demand zones on a Stochastic confirmation, plus a web dashboard that mirrors the
EA's live chart, zones, and signals.

## How it works

`mql5/Experts/SLC_Engine.mq5` is a **single, self-contained file** — everything below is one
class in that file, no local `#include`s to manage:

1. **Structure (HTF)** — `CStructureFilter` scans the high timeframe (default 4H) for rolling
   higher-highs/higher-lows or lower-highs/lower-lows to classify the regime as `UPTREND`,
   `DOWNTREND`, or `CONSOLIDATION`. Consolidation gates everything below it off — the EA stays
   flat.
2. **Level (LTF)** — `CZoneManager` scans the low timeframe (default 5M, the EA's own chart
   period) for expansion legs and captures the last opposite-color candle before the leg as a
   supply/demand zone. Zones that get chopped `ZoneExpiryTouches` times (default 3) without a
   confirmed trade are retired. A broken zone can be flipped back to active on a clean
   break-and-retest, but only while the HTF regime still supports it.
3. **Confirmation** — `CConfirmationEngine` requires a Stochastic %K excursion past the OB/OS
   threshold while price sits in the zone, followed by a crossback within
   `MaxBarsToConfirm` bars. A touch with no crossback is abandoned, not traded.
4. **Execution** — `CRiskExecutor` enters at market on the confirming candle's close, sets SL
   beyond the zone boundary plus a buffer, targets a static `RiskReward` multiple (default 2R),
   and sizes the position off `RiskPercent` of account balance.

Live state (candles, zones, signals, trades) is exported on every change and on a timer to
`<MT5 Common Files>/SLC/state.json` by `CExporter`, which the web dashboard polls.

## Deploying the EA

```bash
make deploy-ea MT5_DATA_DIR="/path/to/your/MetaTrader 5"
```

This copies the single `mql5/Experts/SLC_Engine.mq5` file into that terminal's
`MQL5/Experts/` folder — that's the only file the EA needs. Then in MetaEditor: open
`SLC_Engine.mq5` and compile (F7). Headless compilation isn't automated — `metaeditor64.exe
/compile` is Windows-only and path-dependent, so this stays a manual step.

**Before going live:** backtest and forward-test in the Strategy Tester first. Review every
input (swing lookback, expansion ATR multiple, Stochastic settings, risk %, buffer) against the
symbol and timeframe you intend to trade — the defaults are starting points, not tuned values.

## Web dashboard

```bash
make web
```

Serves `http://localhost:8081` — a candlestick chart with zone rectangles, HTF regime badge,
and lists of active zones/recent signals/recent trades. It reads whatever JSON is at
`$SLC_STATE_FILE` (defaults to the bundled `data/sample_state.json` fixture, so `make web` works
out of the box without a running terminal).

To point it at a live EA:

```bash
SLC_STATE_FILE="/path/to/Common/Files/SLC/state.json" make web
```

MT5's Common Files folder only exists where the terminal itself runs. On this Linux box that
means either running MT5 under Wine locally (Common Files then lives under the Wine prefix) and
pointing `SLC_STATE_FILE` there, or running MT5 on a separate Windows machine and syncing/sharing
that folder to wherever the web server runs.

Regenerate the sample fixture with `make sample-data`.

## Repo layout

```text
mql5/Experts/SLC_Engine.mq5      self-contained EA (structure, zones, confirmation, risk, drawing, export)
web/                              index.html, app.js (lightweight-charts), style.css, server.py
data/sample_state.json           fixture for local web dev
scripts/gen_sample_data.py       regenerates the fixture
```

## Disclaimer

This is a trading tool that places real orders once deployed live. Past performance of any
backtest does not guarantee future results. Use appropriate risk settings, test thoroughly in
a demo account first, and never risk money you can't afford to lose.
