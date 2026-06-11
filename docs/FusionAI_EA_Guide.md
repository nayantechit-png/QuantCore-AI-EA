# FusionAI EA — Setup & Backtest Guide

**One chart. Five pairs. Self-learning.**

FusionAI merges everything that worked across a month of live testing —
GoatFunded v8's pair set and timeframes, QuantCore's indicator ensemble,
and BTAI's self-learning neural network — into a single EA that runs from
**one chart**.

---

## 1. What it trades

| | |
|---|---|
| Pairs | EURUSD, GBPUSD, AUDUSD, NZDUSD, XAUUSD (the GFv8 set) + NAS100 |
| Trend engine | H1 — EMA 20/50/200 stack, ADX/DI, RSI, Kalman filter |
| Entry engine | M30 — range breakout (BRK) or pullback-resume (PBK) |
| AI | One neural network **per symbol** (32→24→12→1), learns from every closed trade |
| Sessions | FX/Gold: London + New York; indices: NY only. Session-edge hours (07/13/16/21 UTC) skipped |

NAS100 resolves automatically to whatever your broker calls it (US100,
USTEC, US100Cash, …) and trades New York hours only.

**Server time is auto-converted to UTC** (`Inp_ServerUTCOffset = 99` = auto).
The dashboard header shows the computed UTC clock — verify it once after
attaching. If it's wrong, set the offset manually (RoboForex in summer = 3).

A trade needs **all three** to agree:
1. An M30 entry trigger fires in the H1 trend direction
2. The weighted indicator ensemble scores ≥ 0.62 with a 0.10 margin over the opposite side
3. The symbol's neural network scores ≥ 0.55 (0.45 during its first 10 trades — bootstrap)

## 2. Install (live / demo)

1. Copy `FusionAI_EA.mq5` to `MQL5/Experts/`, compile in MetaEditor (F7 — must show 0 errors)
2. Copy `FusionAI_GFv8.set` to `MQL5/Presets/`
3. Open **one** chart — EURUSD M30 is recommended
4. Attach FusionAI, load the preset, enable Algo Trading
5. **Do not attach it to any other chart** — it manages all five symbols itself

The dashboard shows one row per symbol: ensemble bull/bear scores, AI score,
training steps (`*` = still bootstrapping), and the current state or skip reason.

### Files it creates (in `MQL5/Files/`)
- `fusion_eurusd.dat` … — one model per symbol (the learned weights)
- `fusion_eurusd_mem.bin` … — open-trade features, so **learning survives
  EA reloads and VPS restarts mid-trade**
- `fusion_log.csv` — every open/close/skip with scores

To reset a symbol's learning, delete its `.dat` and `_mem.bin` files.

## 3. Backtest (MT5 Strategy Tester)

MT5 backtests multi-symbol EAs natively — the tester pulls data for the
other four symbols automatically the first time the EA touches them.

1. Strategy Tester (Ctrl+R) → Expert: **FusionAI_EA**
2. Symbol: **EURUSD**, Period: **M30** (the chart symbol only hosts the EA — all five pairs trade regardless)
3. Modelling: **Every tick based on real ticks** (or "1 minute OHLC" for a fast first pass)
4. Date range: 6–12 months minimum — the AI needs trades to learn from
5. Load `FusionAI_GFv8.set` in the Inputs tab → Start

Notes:
- The first run downloads history for all five symbols; it will be slow once.
- Models train *inside* the backtest exactly as they do live (same code path),
  so a long backtest pre-trains the `.dat` files — run a backtest first and
  the EA starts live already trained.
- For optimization, the dashboard auto-disables itself.

## 4. Risk model (GoatFunded-ready)

| Guard | Default | GoatFunded rule |
|---|---|---|
| Risk per trade | 0.40% | — |
| Daily loss stop | 4.5% | 5% |
| Total loss stop | 9.0% | 10% |
| Max positions at once | 2 | — |
| Max trades/day | 6 (2 per symbol) | — |
| Consecutive losses | 3 → 4 h pause (per symbol) | — |
| Friday | no new trades from 16 UTC, flat by 20 UTC | — |

Sizing is computed from tick value/size directly — there is **no pip math
anywhere**, so the 10× lot-sizing bug class (June 8) cannot recur. The spread
filter and minimum SL are ATR-relative, so they behave identically on Gold
and on FX.

## 5. Trade management

- SL = 1.6 × ATR(M30), TP = 3.0 × ATR (≈ 1.9 R)
- Break-even (+small buffer) locked at **1R**, checked **every tick**
- After break-even: ATR trail at 1.2 × ATR — rides H1 trends, gives back little

## 6. How the learning works

Every closed trade backpropagates into that symbol's network with label
`sigmoid(2 × R-multiple)` — a +1R win teaches ≈0.88, a −1R loss ≈0.12.
Features are stored **before** `OrderSend` (the OnTradeTransaction race that
silently disabled BTAI's learning is fixed by construction) and persisted to
disk (reloads can't orphan an open trade's features). Models save every 5
training steps and on shutdown.

Expect the first ~10 trades per symbol to be exploratory (bootstrap). The
gate tightens automatically once a symbol's model has data.
