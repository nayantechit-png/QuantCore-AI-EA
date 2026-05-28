# QuantCore AI EA — Prop Firm Edition

![Backtest Status](https://github.com/QuantCore/QuantCore-AI-EA/actions/workflows/backtest.yml/badge.svg)
![License](https://img.shields.io/badge/license-MIT-blue)
![MT5](https://img.shields.io/badge/platform-MetaTrader%205-blue)
![Python](https://img.shields.io/badge/python-3.12-green)

**AI-powered Expert Advisor for MetaTrader 5, designed to pass prop firm challenges.**  
Trades Forex major pairs and Gold (XAU/USD) using a 5-component ensemble AI signal engine.

---

## Strategy Overview

| Component | Method | Weight |
|---|---|---|
| **Trend** | EMA 20/50/200 alignment | 30% |
| **Momentum** | RSI(14) + Stochastic | 25% |
| **Regime** | ADX trend strength | 20% |
| **Kalman** | Kalman Filter velocity | 15% |
| **MTF** | H4 confirmation | 10% |

Entry when ensemble score ≥ 0.62. Minimum 1:2 risk/reward enforced by ATR-based SL/TP.

---

## Prop Firm Compliance

| Rule | Default | Notes |
|---|---|---|
| Max daily loss | **4.5%** | 0.5% buffer under FTMO 5% limit |
| Max total drawdown | **9.0%** | 1% buffer under FTMO 10% limit |
| Risk per trade | **0.75%** | Fixed fractional, no martingale |
| Profit lock | **6%** gain | Tightens stops after target |
| RR ratio | **1:2 minimum** | ATR × 1.5 SL, ATR × 3.0 TP |
| No grid / no martingale | ✅ | Single position per direction |
| Friday close | ✅ | Avoids weekend gap risk |
| Max positions | **3** | Configurable |

---

## Supported Instruments

| Symbol (MT5) | Description |
|---|---|
| `EURUSD` | Euro / US Dollar |
| `GBPUSD` | British Pound / US Dollar |
| `USDJPY` | US Dollar / Japanese Yen |
| `USDCHF` | US Dollar / Swiss Franc |
| `AUDUSD` | Australian Dollar / USD |
| `USDCAD` | US Dollar / Canadian Dollar |
| `XAUUSD` | **Gold** / US Dollar |
| `XAGUSD` | Silver / US Dollar |

---

## Quick Start

### 1. Install the EA

```
1. Copy  EA/QuantCore_AI_EA.mq5  →  MetaTrader5/MQL5/Experts/
2. Open MetaEditor (F4) and compile (F7)
3. Drag the EA onto an H1 chart of your chosen symbol
4. Load settings from  EA/QuantCore_AI_EA.set
5. Enable "Allow algorithmic trading"
```

### 2. Backtest in MT5 Strategy Tester

```
1. Open Strategy Tester (Ctrl+R)
2. Select "QuantCore_AI_EA"
3. Set symbol (e.g. XAUUSD), H1, 2023-2024
4. Tick model: "Every tick based on real ticks"
5. Load .set file → Start
```

### 3. Run Python Backtest

```bash
pip install yfinance pandas numpy scipy scikit-learn ta
python backtest/run_backtest.py --symbol EURUSD=X --period 2y
python backtest/run_backtest.py --symbol GC=F     --period 2y
```

---

## Parameter Reference

### Prop Firm Risk
| Parameter | Default | Description |
|---|---|---|
| `Inp_MaxDailyLoss` | 4.5 | Daily loss limit % (EA stops for the day) |
| `Inp_MaxTotalLoss` | 9.0 | Total drawdown limit % (EA stops permanently) |
| `Inp_RiskPerTrade` | 0.75 | % of balance risked per trade |
| `Inp_ProfitLockAt` | 6.0 | Activate profit-lock after X% gain |

### AI Signal Engine
| Parameter | Default | Description |
|---|---|---|
| `Inp_MinScore` | 0.62 | Minimum ensemble score to enter [0.0–1.0] |
| `Inp_EMA_Fast/Mid/Slow` | 20/50/200 | EMA periods |
| `Inp_SL_ATR_Mult` | 1.5 | Stop loss = ATR × this |
| `Inp_TP_ATR_Mult` | 3.0 | Take profit = ATR × this (1:2 RR) |

### Kalman Filter
| Parameter | Default | Description |
|---|---|---|
| `Inp_KF_Delta` | 0.0001 | Process noise — lower = smoother trend |
| `Inp_KF_Ve` | 0.001 | Measurement noise |

---

## GitHub Actions CI

Every push triggers automated backtests across 4 symbols:

```
✅ EUR/USD — 2 year backtest
✅ Gold (XAU/USD) — 2 year backtest  
✅ GBP/USD — 2 year backtest
✅ USD/JPY — 2 year backtest
```

**CI passes when:**
- Prop firm drawdown limit not breached (< 10%)
- Strategy is profitable (net PnL > 0)
- Sharpe ratio > 0

---

## Architecture

```
EA/
├── QuantCore_AI_EA.mq5     ← Main EA (MQL5, standalone)
└── QuantCore_AI_EA.set     ← Default settings

backtest/
└── run_backtest.py         ← Python backtest (mirrors EA logic)

.github/
└── workflows/
    └── backtest.yml        ← CI: runs backtest on every push
```

---

## Disclaimer

This EA is for educational and research purposes.  
Past performance does not guarantee future results.  
Always test on a demo account before live trading.  
Never risk money you cannot afford to lose.

---

## License

MIT — free to use, modify, and distribute.
