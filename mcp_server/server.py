"""
QuantCore MCP Server  (4-in-1)
===============================
Module 1 — Account & Trading  (OANDA REST API)
Module 2 — GoatFunded Dashboard  (Phase-1 progress, MT5 CSV)
Module 3 — Market Data  (yfinance prices, OHLCV, indicators)
Module 4 — Backtest & CI  (run backtests, GitHub Actions status)

Claude Desktop config  (~/.claude/claude_desktop_config.json):
{
  "mcpServers": {
    "quantcore": {
      "command": "/Users/haevay/Desktop/QuantCore-AI-EA/mcp_server/.venv/bin/python",
      "args":["/Users/haevay/Desktop/QuantCore-AI-EA/mcp_server/server.py"],
      "env": {
        "OANDA_API_KEY":     "your_key",
        "OANDA_ACCOUNT_ID":  "your_account_id",
        "OANDA_ENVIRONMENT": "practice",
        "GITHUB_TOKEN":      "optional"
      }
    }
  }
}
"""

import os, sys, json, csv, subprocess, warnings
from datetime import date, timedelta
from pathlib import Path
from typing import Annotated, Optional
from collections import defaultdict
warnings.filterwarnings("ignore")

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT))

from mcp.server.fastmcp import FastMCP
from pydantic import Field

mcp = FastMCP("quantcore_mcp")

# ══════════════════════════════════════════════════════════════════════
#  SHARED UTILS
# ══════════════════════════════════════════════════════════════════════

def _oanda(path: str, method: str = "GET", body: dict = None) -> dict:
    import urllib.request, urllib.error
    key  = os.environ.get("OANDA_API_KEY", "")
    env  = os.environ.get("OANDA_ENVIRONMENT", "practice")
    base = "https://api-fxtrade.oanda.com" if env == "live" else "https://api-fxpractice.oanda.com"
    req  = urllib.request.Request(f"{base}/v3{path}", method=method)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    if body:
        req.data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"error": e.reason, "code": e.code}
    except Exception as e:
        return {"error": str(e)}

def _gh(path: str) -> dict:
    import urllib.request
    token = os.environ.get("GITHUB_TOKEN", "")
    req   = urllib.request.Request(f"https://api.github.com{path}")
    req.add_header("Accept", "application/vnd.github+json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"error": str(e)}

def _yf_price(symbol: str) -> dict:
    import yfinance as yf
    h = yf.Ticker(symbol).history(period="5d", auto_adjust=True)["Close"].dropna()
    if h.empty:
        return {"error": f"No data for {symbol}"}
    last = float(h.iloc[-1])
    prev = float(h.iloc[-2]) if len(h) >= 2 else last
    return {"symbol": symbol, "price": round(last, 5),
            "change_pct": round((last-prev)/prev*100, 3),
            "as_of": str(h.index[-1])[:10]}

DEMO_TRADES = [
    {"date":"2026-05-26","symbol":"XAUUSD","side":"BUY","lots":0.02,"open_px":4520.07,"close_px":4524.49,"profit":8.84,  "comment":""},
    {"date":"2026-05-26","symbol":"XAUUSD","side":"BUY","lots":0.20,"open_px":4519.30,"close_px":4524.49,"profit":103.80,"comment":""},
    {"date":"2026-05-26","symbol":"XAUUSD","side":"BUY","lots":0.20,"open_px":4525.05,"close_px":4519.58,"profit":-109.40,"comment":""},
    {"date":"2026-05-26","symbol":"XAUUSD","side":"BUY","lots":0.20,"open_px":4513.29,"close_px":4519.64,"profit":127.00,"comment":""},
    {"date":"2026-05-26","symbol":"XAUUSD","side":"BUY","lots":0.20,"open_px":4510.01,"close_px":4519.64,"profit":192.60,"comment":""},
    {"date":"2026-05-26","symbol":"GBPUSD","side":"BUY","lots":7.43,"open_px":1.34602,"close_px":1.34687,"profit":631.55,"comment":"GFv8_M30_L"},
    {"date":"2026-05-27","symbol":"AUDUSD","side":"BUY","lots":8.25,"open_px":0.71383,"close_px":0.71456,"profit":602.25,"comment":"GFv8_M30_L"},
    {"date":"2026-05-27","symbol":"NZDUSD","side":"SELL","lots":8.27,"open_px":0.59006,"close_px":0.58933,"profit":603.71,"comment":"GFv8_M30_S"},
    {"date":"2026-05-27","symbol":"XAUUSD","side":"BUY","lots":0.29,"open_px":4434.51,"close_px":4451.84,"profit":502.57,"comment":"GFv8_H1_L"},
    {"date":"2026-05-28","symbol":"EURUSD","side":"BUY","lots":4.10,"open_px":1.16327,"close_px":1.16460,"profit":545.30,"comment":"QuantCore[0.696]|0.127"},
]

def _parse_csv(path: str) -> list:
    trades = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        sample = f.read(2048); f.seek(0)
        try:    dialect = csv.Sniffer().sniff(sample, delimiters=",;\t")
        except: dialect = csv.excel
        for row in csv.DictReader(f, dialect=dialect):
            try:
                r = {k.strip().lower(): v.strip() for k,v in row.items()}
                trades.append({"date":r.get("time",r.get("open time",""))[:10],
                    "symbol":r.get("symbol",""),"side":r.get("type",r.get("direction","")).upper(),
                    "lots":float(r.get("volume",r.get("lots",0))or 0),
                    "open_px":float(r.get("price",r.get("open price",0))or 0),
                    "close_px":float(r.get("close price",r.get("price (2)",0))or 0),
                    "profit":float(r.get("profit",0)or 0),"comment":r.get("comment","")})
            except: pass
    return trades

def _stats(trades: list, deposit: float, tgt_pct: float, max_daily: float, max_total: float) -> dict:
    wins  = [t for t in trades if t["profit"]>0]
    losses= [t for t in trades if t["profit"]<0]
    pnl   = sum(t["profit"] for t in trades)
    bal   = deposit + pnl
    daily: dict = defaultdict(float)
    for t in trades: daily[t["date"]] += t["profit"]
    today_pnl  = daily.get(date.today().isoformat(), 0.0)
    days_act   = max(1, len(daily))
    avg_day    = pnl / days_act
    tgt        = deposit * tgt_pct / 100
    rem        = max(0, tgt - pnl)
    phase_pct  = min(100, pnl/tgt*100) if tgt>0 else 0
    dd         = max(0, (deposit-bal)/deposit*100)
    gw = sum(t["profit"] for t in wins)
    gl = abs(sum(t["profit"] for t in losses))
    d_cur  = int(rem/avg_day+1) if avg_day>0 and rem>0 else 0
    d_3sym = int(rem/(avg_day*3.5)+1) if avg_day>0 and rem>0 else 0
    return dict(balance=round(bal,2),deposit=deposit,total_pnl=round(pnl,2),
        net_pct=round(pnl/deposit*100,2),today_pnl=round(today_pnl,2),
        phase_pct=round(phase_pct,1),remaining=round(rem,2),target=round(tgt,2),
        drawdown_pct=round(dd,2),avg_daily=round(avg_day,2),
        days_cur=d_cur,days_3sym=d_3sym,
        pass_date_cur=(date.today()+timedelta(days=d_cur)).isoformat() if d_cur>0 else "PASSED",
        pass_date_3sym=(date.today()+timedelta(days=d_3sym)).isoformat() if d_3sym>0 else "PASSED",
        total_trades=len(trades),wins=len(wins),losses=len(losses),
        win_rate=round(len(wins)/len(trades)*100,1) if trades else 0,
        profit_factor=round(gw/gl,2) if gl>0 else 999,
        avg_win=round(gw/len(wins),2) if wins else 0,
        avg_loss=round(gl/len(losses),2) if losses else 0,
        daily=dict(daily))


# ══════════════════════════════════════════════════════════════════════
#  MODULE 1 — ACCOUNT & TRADING
# ══════════════════════════════════════════════════════════════════════

@mcp.tool(name="quantcore_get_account",
          description="Live OANDA account: balance, equity, unrealized P&L, margin, open trade count.",
          annotations={"readOnlyHint":True,"openWorldHint":True})
def quantcore_get_account(
    response_format: Annotated[str, Field(description="'markdown' or 'json'")] = "markdown"
) -> str:
    acct = os.environ.get("OANDA_ACCOUNT_ID","")
    if not acct: return "❌ Set OANDA_ACCOUNT_ID in env."
    d = _oanda(f"/accounts/{acct}/summary")
    if "error" in d: return f"❌ OANDA: {d['error']}"
    a = d.get("account",{})
    r = dict(id=a.get("id"), currency=a.get("currency"),
             balance=float(a.get("balance",0)), nav=float(a.get("NAV",0)),
             unrealized=float(a.get("unrealizedPL",0)), realized=float(a.get("pl",0)),
             margin_used=float(a.get("marginUsed",0)), margin_free=float(a.get("marginAvailable",0)),
             open_trades=int(a.get("openTradeCount",0)))
    if response_format=="json": return json.dumps(r,indent=2)
    return (f"## 💰 Account — {r['id']}\n|Field|Value|\n|---|---|\n"
            f"|Balance|**${r['balance']:,.2f}**|\n|NAV|**${r['nav']:,.2f}**|\n"
            f"|Unrealized P&L|${r['unrealized']:+,.2f}|\n|Realized P&L|${r['realized']:+,.2f}|\n"
            f"|Margin Used|${r['margin_used']:,.2f}|\n|Margin Free|${r['margin_free']:,.2f}|\n"
            f"|Open Trades|{r['open_trades']}|")


@mcp.tool(name="quantcore_get_positions",
          description="All open OANDA positions: symbol, side, units, avg price, unrealized P&L.",
          annotations={"readOnlyHint":True,"openWorldHint":True})
def quantcore_get_positions(
    response_format: Annotated[str, Field(description="'markdown' or 'json'")] = "markdown"
) -> str:
    acct = os.environ.get("OANDA_ACCOUNT_ID","")
    if not acct: return "❌ Set OANDA_ACCOUNT_ID in env."
    d = _oanda(f"/accounts/{acct}/openPositions")
    if "error" in d: return f"❌ {d['error']}"
    pos = []
    for p in d.get("positions",[]):
        for side,key in [("LONG","long"),("SHORT","short")]:
            s=p.get(key,{})
            if int(s.get("units",0))!=0:
                pos.append({"symbol":p["instrument"].replace("_","/"),"side":side,
                    "units":abs(int(s["units"])),"avg":float(s.get("averagePrice",0)),
                    "pnl":float(s.get("unrealizedPL",0))})
    if not pos: return "📭 No open positions."
    if response_format=="json": return json.dumps(pos,indent=2)
    rows = ["## 📊 Open Positions\n|Symbol|Side|Units|Avg Price|P&L|","|---|---|---|---|---|"]
    for p in pos:
        rows.append(f"|{p['symbol']}|{p['side']}|{p['units']:,}|{p['avg']:.5f}|"
                    f"{'🟢' if p['pnl']>=0 else '🔴'} ${p['pnl']:+,.2f}|")
    return "\n".join(rows)


@mcp.tool(name="quantcore_place_order",
          description="Place a market order on OANDA. Positive units=buy, negative=sell.",
          annotations={"readOnlyHint":False,"destructiveHint":False,"openWorldHint":True})
def quantcore_place_order(
    symbol: Annotated[str,   Field(description="OANDA instrument e.g. EUR_USD, XAU_USD")],
    units:  Annotated[float, Field(description="Units to trade. Positive=buy, negative=sell.")],
) -> str:
    acct = os.environ.get("OANDA_ACCOUNT_ID","")
    if not acct: return "❌ Set OANDA_ACCOUNT_ID in env."
    d = _oanda(f"/accounts/{acct}/orders","POST",
               {"order":{"type":"MARKET","instrument":symbol,"units":str(int(units))}})
    if "error" in d: return f"❌ Order failed: {d['error']}"
    fill = d.get("orderFillTransaction",{})
    return (f"✅ Filled — {symbol} | Units: {fill.get('units')} | "
            f"Price: {fill.get('price')} | Trade: {fill.get('tradeOpened',{}).get('tradeID','N/A')}")


@mcp.tool(name="quantcore_close_position",
          description="Close all units of an open OANDA position by instrument symbol.",
          annotations={"readOnlyHint":False,"openWorldHint":True})
def quantcore_close_position(
    symbol: Annotated[str, Field(description="OANDA instrument e.g. EUR_USD")]
) -> str:
    acct = os.environ.get("OANDA_ACCOUNT_ID","")
    if not acct: return "❌ Set OANDA_ACCOUNT_ID in env."
    d = _oanda(f"/accounts/{acct}/positions/{symbol}/close","PUT",
               {"longUnits":"ALL","shortUnits":"ALL"})
    if "error" in d: return f"❌ Close failed: {d['error']}"
    pnl = sum(float(d.get(k,{}).get("pl",0) or 0) for k in
              ["longOrderFillTransaction","shortOrderFillTransaction"])
    return f"✅ Closed {symbol} | Realized P&L: ${pnl:+,.2f}"


# ══════════════════════════════════════════════════════════════════════
#  MODULE 2 — GOATFUNDED DASHBOARD
# ══════════════════════════════════════════════════════════════════════

@mcp.tool(name="quantcore_phase_status",
          description="GoatFunded Phase-1 dashboard: balance, P&L, drawdown, days to pass target, trade stats. Loads from MT5 history CSV or uses built-in demo data.",
          annotations={"readOnlyHint":True})
def quantcore_phase_status(
    csv_path:        Annotated[Optional[str], Field(description="MT5 History CSV path. Omit for demo.")] = None,
    deposit:         Annotated[float, Field(description="Starting deposit")] = 100000.0,
    target_pct:      Annotated[float, Field(description="Phase profit target %")] = 8.0,
    max_daily:       Annotated[float, Field(description="Broker daily loss limit %")] = 5.0,
    max_total:       Annotated[float, Field(description="Broker total DD limit %")] = 10.0,
    response_format: Annotated[str,   Field(description="'markdown' or 'json'")] = "markdown",
) -> str:
    trades = _parse_csv(csv_path) if csv_path else DEMO_TRADES
    s = _stats(trades, deposit, target_pct, max_daily, max_total)
    if response_format=="json": return json.dumps(s, indent=2)
    safe = "✅ SAFE" if s["drawdown_pct"]<max_daily*0.5 else "⚠️ WATCH" if s["drawdown_pct"]<max_daily*0.8 else "🚨 DANGER"
    return (
        f"## 🎯 GoatFunded Phase-1\n\n"
        f"### 💰 Account\n|Field|Value|\n|---|---|\n"
        f"|Balance|**${s['balance']:,.2f}**|\n"
        f"|Net P&L|**${s['total_pnl']:+,.2f}** ({s['net_pct']:+.2f}%)|\n"
        f"|Today|${s['today_pnl']:+,.2f}|\n"
        f"|Avg/day|${s['avg_daily']:,.2f}|\n\n"
        f"### 📈 Phase Progress — {target_pct:.0f}% target\n"
        f"**{s['phase_pct']:.1f}%** complete — **${s['remaining']:,.2f}** remaining\n\n"
        f"|Scenario|Pass Date|Days|\n|---|---|---|\n"
        f"|1 symbol|{s['pass_date_cur']}|~{s['days_cur']}|\n"
        f"|3 symbols 🚀|**{s['pass_date_3sym']}**|**~{s['days_3sym']}**|\n\n"
        f"### 🛡 Safety — {safe}\n"
        f"|Limit|Used|Buffer|\n|---|---|---|\n"
        f"|Daily {max_daily:.0f}%|{s['drawdown_pct']:.2f}%|{max(0,max_daily-s['drawdown_pct']):.2f}%|\n"
        f"|Total {max_total:.0f}%|{s['drawdown_pct']:.2f}%|{max(0,max_total-s['drawdown_pct']):.2f}%|\n\n"
        f"### 📊 Stats\nTrades: {s['total_trades']} | WR: **{s['win_rate']:.1f}%** | "
        f"PF: **{s['profit_factor']:.2f}** | Avg Win: ${s['avg_win']:,.2f}\n"
    )


@mcp.tool(name="quantcore_trade_history",
          description="Return recent trades from an MT5 history CSV with optional symbol/EA filter.",
          annotations={"readOnlyHint":True})
def quantcore_trade_history(
    csv_path:        Annotated[str,          Field(description="Path to MT5 History CSV")] = "",
    limit:           Annotated[int,          Field(description="Max trades to return")] = 20,
    symbol:          Annotated[Optional[str],Field(description="Filter by symbol")] = None,
    ea_filter:       Annotated[Optional[str],Field(description="Filter by EA comment")] = None,
    response_format: Annotated[str,          Field(description="'markdown' or 'json'")] = "markdown",
) -> str:
    if not csv_path:
        trades = list(DEMO_TRADES)
    elif not Path(csv_path).exists():
        return f"❌ File not found: {csv_path}"
    else:
        trades = _parse_csv(csv_path)
    if symbol:    trades = [t for t in trades if symbol.upper() in t["symbol"].upper()]
    if ea_filter: trades = [t for t in trades if ea_filter.lower() in t["comment"].lower()]
    trades = sorted(trades, key=lambda x: x["date"], reverse=True)[:limit]
    if not trades: return "📭 No trades found."
    if response_format=="json": return json.dumps(trades, indent=2)
    rows = [f"## 📋 Trade History ({len(trades)} trades)\n",
            "|Date|Symbol|Side|Lots|Open|Close|P&L|EA|","|---|---|---|---|---|---|---|---|"]
    for t in trades:
        ea = "✨ QuantCore" if "QuantCore" in t["comment"] else t["comment"][:12] or "—"
        rows.append(f"|{t['date']}|{t['symbol']}|{t['side']}|{t['lots']:.2f}|"
                    f"{t['open_px']:.5f}|{t['close_px']:.5f}|"
                    f"{'🟢' if t['profit']>=0 else '🔴'} ${t['profit']:+,.2f}|{ea}|")
    return "\n".join(rows)


# ══════════════════════════════════════════════════════════════════════
#  MODULE 3 — MARKET DATA
# ══════════════════════════════════════════════════════════════════════

@mcp.tool(name="quantcore_get_price",
          description="Current price and daily change for any Yahoo Finance symbols (forex, gold, stocks). Accepts comma-separated list.",
          annotations={"readOnlyHint":True,"openWorldHint":True})
def quantcore_get_price(
    symbols:         Annotated[str, Field(description="Comma-separated Yahoo Finance symbols, e.g. 'EURUSD=X,GC=F,AAPL'")] = "EURUSD=X,GC=F,GBPUSD=X",
    response_format: Annotated[str, Field(description="'markdown' or 'json'")] = "markdown",
) -> str:
    results = [_yf_price(s.strip()) for s in symbols.split(",")]
    if response_format=="json": return json.dumps(results, indent=2)
    rows = ["## 📈 Market Prices\n|Symbol|Price|Change|As Of|","|---|---|---|---|"]
    for r in results:
        if "error" in r:
            rows.append(f"|❌|{r['error']}|||")
        else:
            ic = "🟢" if r["change_pct"]>=0 else "🔴"
            rows.append(f"|{r['symbol']}|**{r['price']}**|{ic} {r['change_pct']:+.3f}%|{r['as_of']}|")
    return "\n".join(rows)


@mcp.tool(name="quantcore_get_ohlcv",
          description="OHLCV candlestick bars for any symbol at any interval (1m, 5m, 1h, 4h, 1d).",
          annotations={"readOnlyHint":True,"openWorldHint":True})
def quantcore_get_ohlcv(
    symbol:          Annotated[str, Field(description="Yahoo Finance symbol e.g. EURUSD=X")] = "EURUSD=X",
    interval:        Annotated[str, Field(description="Bar interval: 1m 5m 15m 1h 4h 1d")] = "1h",
    period:          Annotated[str, Field(description="History window: 1d 5d 1mo 3mo 1y 2y")] = "5d",
    limit:           Annotated[int, Field(description="Number of bars (max 100)")] = 24,
    response_format: Annotated[str, Field(description="'markdown' or 'json'")] = "markdown",
) -> str:
    import yfinance as yf, pandas as pd
    df = yf.download(symbol, period=period, interval=interval,
                     progress=False, auto_adjust=True)
    if isinstance(df.columns, pd.MultiIndex): df.columns = df.columns.get_level_values(0)
    df.columns = df.columns.str.lower()
    df = df.dropna().tail(min(limit,100))
    if df.empty: return f"❌ No OHLCV for {symbol}"
    if response_format=="json":
        return df.reset_index().to_json(orient="records", date_format="iso", indent=2)
    rows = [f"## 📊 {symbol} OHLCV ({interval})\n|Time|Open|High|Low|Close|","|---|---|---|---|---|"]
    for ts, row in df.iterrows():
        rows.append(f"|{str(ts)[:16]}|{row['open']:.5f}|{row['high']:.5f}|"
                    f"{row['low']:.5f}|**{row['close']:.5f}**|")
    return "\n".join(rows)


@mcp.tool(name="quantcore_get_indicators",
          description="Live technical indicators for any symbol: ATR, RSI, EMA 20/50/200, trend direction, Kalman velocity.",
          annotations={"readOnlyHint":True,"openWorldHint":True})
def quantcore_get_indicators(
    symbol:          Annotated[str, Field(description="Yahoo Finance symbol e.g. EURUSD=X")] = "EURUSD=X",
    interval:        Annotated[str, Field(description="Bar interval: 1h 4h 1d")] = "1h",
    period:          Annotated[str, Field(description="History window")] = "6mo",
    response_format: Annotated[str, Field(description="'markdown' or 'json'")] = "markdown",
) -> str:
    import yfinance as yf, pandas as pd
    df = yf.download(symbol, period=period, interval=interval,
                     progress=False, auto_adjust=True)
    if isinstance(df.columns, pd.MultiIndex): df.columns = df.columns.get_level_values(0)
    df.columns = df.columns.str.lower()
    df = df.dropna()
    if len(df) < 50: return f"❌ Not enough data ({len(df)} bars)"
    c = df["close"]; h = df["high"]; l = df["low"]
    tr = pd.concat([h-l,(h-c.shift()).abs(),(l-c.shift()).abs()],axis=1).max(axis=1)
    atr   = float(tr.ewm(alpha=1/14,adjust=False).mean().iloc[-1])
    d     = c.diff()
    gain  = d.clip(lower=0).rolling(14).mean()
    loss  = (-d.clip(upper=0)).rolling(14).mean()
    rsi   = float(100 - 100/(1+gain.iloc[-1]/max(loss.iloc[-1],1e-9)))
    ema20 = float(c.ewm(span=20, adjust=False).mean().iloc[-1])
    ema50 = float(c.ewm(span=50, adjust=False).mean().iloc[-1])
    ema200= float(c.ewm(span=200,adjust=False).mean().iloc[-1])
    last  = float(c.iloc[-1])
    bull  = last>ema20>ema50>ema200; bear = last<ema20<ema50<ema200
    trend = "🟢 BULL" if bull else "🔴 BEAR" if bear else "🟡 MIXED"
    # Kalman velocity
    P=1.0; th=float(c.iloc[0]); vel=0.0
    for p in c.values:
        Pp=P+0.0001/0.9999; K=Pp/(Pp+0.001); nt=th+K*(p-th); vel=nt-th; th=nt; P=(1-K)*Pp
    r = dict(symbol=symbol,price=round(last,5),atr=round(atr,5),atr_pct=round(atr/last*100,3),
             rsi=round(rsi,2),ema20=round(ema20,5),ema50=round(ema50,5),ema200=round(ema200,5),
             trend=trend,kalman_vel=round(vel,7))
    if response_format=="json": return json.dumps(r,indent=2)
    return (f"## 📐 Indicators — {symbol} ({interval})\n|Indicator|Value|\n|---|---|\n"
            f"|Price|**{r['price']}**|\n|ATR(14)|{r['atr']} ({r['atr_pct']}%)|\n"
            f"|RSI(14)|{'🔴 OB ' if rsi>70 else '🟢 OS ' if rsi<30 else ''}{r['rsi']}|\n"
            f"|EMA 20|{r['ema20']}|\n|EMA 50|{r['ema50']}|\n|EMA 200|{r['ema200']}|\n"
            f"|Trend|{trend}|\n|Kalman vel|{r['kalman_vel']}|")


@mcp.tool(name="quantcore_get_signal",
          description="Run the full 5-component QuantCore AI ensemble (Trend+Momentum+Regime+Kalman+MTF) and return bull/bear score with BUY/SELL/WAIT recommendation.",
          annotations={"readOnlyHint":True,"openWorldHint":True})
def quantcore_get_signal(
    symbol:    Annotated[str,   Field(description="Yahoo Finance symbol e.g. EURUSD=X or GC=F")] = "EURUSD=X",
    min_score: Annotated[float, Field(description="Entry threshold (default 0.58)")] = 0.58,
) -> str:
    try:
        sys.path.insert(0, str(ROOT/"backtest"))
        from run_backtest import fetch, build_features, PARAMS
        p = dict(PARAMS); p["min_score"] = min_score
        h1 = fetch(symbol,"3mo","1h"); h4 = fetch(symbol,"3mo","4h")
        if len(h1)<250: return f"❌ Not enough data ({len(h1)} bars)"
        feat  = build_features(h1,h4,p)
        bull  = float(feat["bull"].iloc[-1]); bear = float(feat["bear"].iloc[-1])
        price = float(feat["close"].iloc[-1]); atr  = float(feat["atr"].iloc[-1])
        if bull>=min_score and bear<min_score:
            rec=f"🟢 **BUY** — bull score {bull:.3f}"
            sl=round(price-atr*1.5,5); tp=round(price+atr*3.5,5)
        elif bear>=min_score and bull<min_score:
            rec=f"🔴 **SELL** — bear score {bear:.3f}"
            sl=round(price+atr*1.5,5); tp=round(price-atr*3.5,5)
        else:
            rec=f"⚪ **WAIT** — bull {bull:.3f} / bear {bear:.3f}  (threshold {min_score})"
            sl=tp=None
        lines=[f"## ⚡ QuantCore Signal — {symbol}\n{rec}\n",
               f"|Component|Value|\n|---|---|",
               f"|Price|{price:.5f}|",f"|Bull score|{bull:.4f}|",
               f"|Bear score|{bear:.4f}|",f"|ATR(14)|{atr:.5f}|"]
        if sl: lines+=[f"|SL (1.5×ATR)|{sl}|",f"|TP (3.5×ATR)|{tp}|"]
        return "\n".join(lines)
    except Exception as e:
        return f"❌ Signal error: {e}"


# ══════════════════════════════════════════════════════════════════════
#  MODULE 4 — BACKTEST & CI
# ══════════════════════════════════════════════════════════════════════

@mcp.tool(name="quantcore_run_backtest",
          description="Run the QuantCore Python backtest on any symbol/period. Returns net P&L, max drawdown, Sharpe, win rate, and prop-firm pass/fail.",
          annotations={"readOnlyHint":True})
def quantcore_run_backtest(
    symbol:   Annotated[str,   Field(description="Yahoo Finance symbol e.g. EURUSD=X")] = "EURUSD=X",
    period:   Annotated[str,   Field(description="History period: 1y 2y 3y")] = "2y",
    balance:  Annotated[float, Field(description="Starting balance for simulation")] = 10000.0,
) -> str:
    script = ROOT/"backtest"/"run_backtest.py"
    if not script.exists(): return f"❌ Script not found: {script}"
    result = subprocess.run(
        [sys.executable, str(script), "--symbol", symbol, "--period", period, "--balance", str(balance)],
        capture_output=True, text=True, timeout=300, cwd=str(ROOT))
    out = (result.stdout+result.stderr).strip()
    icon = "✅" if result.returncode==0 else "❌"
    return f"## {icon} Backtest — {symbol} ({period})\n\n```\n{out}\n```"


@mcp.tool(name="quantcore_get_ci_status",
          description="GitHub Actions CI status for QuantCore-AI-EA: latest backtest run results and per-step pass/fail.",
          annotations={"readOnlyHint":True,"openWorldHint":True})
def quantcore_get_ci_status(
    owner: Annotated[str, Field(description="GitHub owner")] = "nayantechit-png",
    repo:  Annotated[str, Field(description="GitHub repo")] = "QuantCore-AI-EA",
    limit: Annotated[int, Field(description="Recent runs to show")] = 5,
) -> str:
    d = _gh(f"/repos/{owner}/{repo}/actions/runs?per_page={limit}")
    if "error" in d: return f"❌ {d['error']}"
    runs = d.get("workflow_runs",[])
    if not runs: return "📭 No workflow runs."
    rows = [f"## 🤖 CI — {owner}/{repo}\n|Run|Status|Result|Branch|","|---|---|---|---|"]
    for r in runs:
        ic = "✅" if r["conclusion"]=="success" else "❌" if r["conclusion"]=="failure" else "⏳"
        msg = r["head_commit"]["message"].split("\n")[0][:40]
        rows.append(f"|#{r['run_number']}|{r['status']}|{ic} {r['conclusion'] or 'running'}|{r['head_branch']} — {msg}|")
    # steps for latest
    jobs = _gh(f"/repos/{owner}/{repo}/actions/runs/{runs[0]['id']}/jobs")
    if "jobs" in jobs:
        rows.append(f"\n### Latest Run #{runs[0]['run_number']}")
        for j in jobs["jobs"]:
            rows.append(f"\n**{'✅' if j['conclusion']=='success' else '❌'} {j['name']}**")
            for step in j.get("steps",[]):
                if any(k in step["name"] for k in ["Backtest","Validate"]):
                    rows.append(f"  {'✅' if step['conclusion']=='success' else '❌'} {step['name']}")
    return "\n".join(rows)


@mcp.tool(name="quantcore_optimize_params",
          description="Recommend optimal QuantCore EA parameters based on current account state. Returns parameter table with expected daily profit and phase-pass forecast.",
          annotations={"readOnlyHint":True})
def quantcore_optimize_params(
    deposit:   Annotated[float, Field(description="Account deposit")] = 100000.0,
    balance:   Annotated[float, Field(description="Current balance")] = 103183.0,
    avg_daily: Annotated[float, Field(description="Average daily P&L so far")] = 1071.0,
    target_pct:Annotated[float, Field(description="Phase target %")] = 8.0,
) -> str:
    rem    = max(0, deposit*target_pct/100 - (balance-deposit))
    d_cur  = int(rem/avg_daily+1)   if avg_daily>0 else 999
    d_3sym = int(rem/avg_daily/3.5+1) if avg_daily>0 else 999
    return (
        f"## ⚙️ Parameter Optimizer\n\n"
        f"Balance: **${balance:,.2f}** | Remaining: **${rem:,.2f}**\n\n"
        f"|Parameter|Current|→ Recommended|Impact|\n|---|---|---|---|\n"
        f"|`Inp_RiskPerTrade`|0.75%|**1.00%**|+33% per trade|\n"
        f"|`Inp_MinScore`|0.62|**0.58**|~50% more signals|\n"
        f"|`Inp_TP_ATR_Mult`|3.0|**3.5**|+17% per win|\n"
        f"|`Inp_Trail_ATR`|1.0|**0.80**|Hold winners longer|\n"
        f"|Symbols|EURUSD|**+GBPUSD +XAUUSD**|3× opportunities|\n\n"
        f"|Scenario|Daily Est.|Pass Date|Days|\n|---|---|---|---|\n"
        f"|Current (1 symbol)|${avg_daily:,.0f}|~{d_cur} days|{d_cur}|\n"
        f"|3 symbols + new params|${avg_daily*3.5:,.0f}|**~{d_3sym} days 🚀**|{d_3sym}|\n"
    )


# ══════════════════════════════════════════════════════════════════════
#  MODULE 5 — LSTM FORECASTER
# ══════════════════════════════════════════════════════════════════════

@mcp.tool(name="quantcore_lstm_forecast",
          description="Train a 2-layer PyTorch LSTM on price history and predict next-bar direction (BUY/SELL/NEUTRAL) with probability and confidence level.",
          annotations={"readOnlyHint":True,"openWorldHint":True})
def quantcore_lstm_forecast(
    symbol:    Annotated[str,   Field(description="Yahoo Finance symbol e.g. EURUSD=X or GC=F")] = "EURUSD=X",
    period:    Annotated[str,   Field(description="Training history: 1y 2y 3y")] = "2y",
    interval:  Annotated[str,   Field(description="Bar interval: 1h 4h 1d")] = "1h",
    epochs:    Annotated[int,   Field(description="Max training epochs (20-100)")] = 60,
    model_path:Annotated[Optional[str], Field(description="Load pre-trained .pt file instead of training")] = None,
) -> str:
    try:
        sys.path.insert(0, str(ROOT))
        from quantcore.strategies.lstm_forecaster import LSTMForecaster
        f = LSTMForecaster(window=30, epochs=epochs, patience=10)
        if model_path and Path(model_path).exists():
            f.load(model_path)
            prob, dirn, conf = f.predict_next(symbol, interval)
            lines = [f"## 🧠 LSTM Forecast — {symbol} (pre-trained)\n"]
        else:
            r = f.train(symbol, period, interval, verbose=False)
            prob, dirn, conf = f.predict_next(symbol, interval)
            lines = [
                f"## 🧠 LSTM Forecast — {symbol}\n",
                f"**Training complete** | Test acc: {r['test_acc']}% | "
                f"Confident bars: {r['confident_pct']}%\n",
            ]
        bar = "█"*int(prob*20) + "░"*(20-int(prob*20))
        icon = "🟢" if dirn=="BUY" else "🔴" if dirn=="SELL" else "⚪"
        conf_icon = "🔥" if conf=="HIGH" else "⚡" if conf=="MEDIUM" else "💤"
        lines += [
            f"|Field|Value|\n|---|---|",
            f"|Direction|{icon} **{dirn}**|",
            f"|P(up next bar)|{prob:.4f}  `{bar}`|",
            f"|Confidence|{conf_icon} {conf}|",
            f"\n> Use alongside `quantcore_get_signal` — LSTM adds directional conviction when confidence is HIGH.",
        ]
        return "\n".join(lines)
    except ImportError as e:
        return f"❌ PyTorch not installed in venv: {e}\nRun: mcp_server/.venv/bin/pip install torch"
    except Exception as e:
        return f"❌ LSTM error: {e}"


@mcp.tool(name="quantcore_genetic_optimize",
          description="Run Genetic Algorithm to evolve optimal QuantCore signal weights and strategy parameters. Returns ready-to-paste .set file values.",
          annotations={"readOnlyHint":True})
def quantcore_genetic_optimize(
    symbol:      Annotated[str,   Field(description="Yahoo Finance symbol e.g. EURUSD=X")] = "EURUSD=X",
    period:      Annotated[str,   Field(description="History: 1y 2y")] = "2y",
    generations: Annotated[int,   Field(description="GA generations (30=fast, 80=thorough)")] = 50,
    pop_size:    Annotated[int,   Field(description="Population size (20-50)")] = 30,
) -> str:
    try:
        sys.path.insert(0, str(ROOT))
        from quantcore.strategies.genetic_optimizer import GeneticOptimizer
        ga   = GeneticOptimizer(pop_size=pop_size, generations=generations)
        best = ga.run(symbol, period, verbose=False)
        g    = best.genes / best.genes[:5].sum() * best.genes[:5].sum()  # already normalised
        import numpy as np; g = best.genes.copy(); g[:5] /= g[:5].sum()
        return (
            f"## 🧬 Genetic Optimizer — {symbol}\n\n"
            f"**Fitness: {best.score:.4f}** (gen {best.generation}/{generations})\n\n"
            f"|Metric|Value|\n|---|---|\n"
            f"|Net P&L|{best.backtest.get('net_pnl_pct',0):+.1f}%|\n"
            f"|Max Drawdown|{best.backtest.get('max_drawdown_pct',0):.1f}%|\n"
            f"|Sharpe|{best.backtest.get('sharpe',0):.3f}|\n"
            f"|Win Rate|{best.backtest.get('win_rate_pct',0):.1f}%|\n\n"
            f"### 📋 Paste into `QuantCore_AI_EA.set`\n\n"
            f"```ini\n"
            f"W_Trend={g[0]:.4f}\n"
            f"W_Momentum={g[1]:.4f}\n"
            f"W_Regime={g[2]:.4f}\n"
            f"W_Kalman={g[3]:.4f}\n"
            f"W_MTF={g[4]:.4f}\n"
            f"Inp_MinScore={g[5]:.3f}\n"
            f"Inp_SL_ATR_Mult={g[6]:.2f}\n"
            f"Inp_TP_ATR_Mult={g[7]:.2f}\n"
            f"Inp_RiskPerTrade={g[8]:.2f}\n"
            f"```"
        )
    except Exception as e:
        return f"❌ GA error: {e}"


@mcp.tool(name="quantcore_rl_predict",
          description="Run PPO/A2C Reinforcement Learning agent: train on price history and return LONG/SHORT/HOLD action recommendation.",
          annotations={"readOnlyHint":True,"openWorldHint":True})
def quantcore_rl_predict(
    symbol:      Annotated[str, Field(description="Yahoo Finance symbol e.g. EURUSD=X")] = "EURUSD=X",
    period:      Annotated[str, Field(description="Training history: 1y 2y")] = "2y",
    total_steps: Annotated[int, Field(description="Training timesteps (100k=fast, 500k=quality)")] = 200_000,
    algo:        Annotated[str, Field(description="'PPO' or 'A2C'")] = "PPO",
    model_path:  Annotated[Optional[str], Field(description="Load pre-trained .zip instead of training")] = None,
) -> str:
    try:
        sys.path.insert(0, str(ROOT))
        from quantcore.strategies.rl_agent import RLAgent
        agent = RLAgent(algo=algo, total_steps=total_steps)
        if model_path and Path(model_path).exists():
            agent.load(model_path, symbol)
            action, _ = agent.predict(symbol)
            return (f"## 🤖 RL Agent ({algo}) — {symbol} (pre-trained)\n\n"
                    f"**Recommendation: {'🟢 LONG' if action=='LONG' else '🔴 SHORT' if action=='SHORT' else '⚪ HOLD'}**\n")
        r = agent.train(symbol, period, verbose=False)
        action, _ = agent.predict(symbol)
        icons = {"LONG":"🟢","SHORT":"🔴","HOLD":"⚪"}
        return (
            f"## 🤖 RL Agent ({algo}) — {symbol}\n\n"
            f"**Recommendation: {icons.get(action,'')} {action}**\n\n"
            f"|Training Metric|Value|\n|---|---|\n"
            f"|Steps|{r['total_steps']:,}|\n"
            f"|Test Return|{r['return_pct']:+.2f}%|\n"
            f"|Final Balance|${r['final_balance']:,.2f}|\n"
            f"|Sharpe|{r['sharpe']:.3f}|\n\n"
            f"> For better results use `total_steps=500000`. "
            f"Combine with `quantcore_get_signal` for confirmation."
        )
    except ImportError as e:
        return f"❌ Missing packages: {e}\nRun: mcp_server/.venv/bin/pip install gymnasium stable-baselines3"
    except Exception as e:
        return f"❌ RL error: {e}"


@mcp.tool(name="quantcore_send_alert",
          description="Send a trading alert to Telegram and/or Discord. Types: signal, trade_opened, trade_closed, phase_update, safety_warning, phase_passed.",
          annotations={"readOnlyHint":False,"openWorldHint":True})
def quantcore_send_alert(
    alert_type: Annotated[str,   Field(description="signal|trade_opened|trade_closed|phase_update|safety_warning|phase_passed")] = "signal",
    symbol:     Annotated[str,   Field(description="Trading symbol e.g. EURUSD")] = "EURUSD",
    direction:  Annotated[str,   Field(description="BUY or SELL")] = "BUY",
    score:      Annotated[float, Field(description="Signal score 0-1")] = 0.696,
    price:      Annotated[float, Field(description="Entry/current price")] = 1.16327,
    sl:         Annotated[float, Field(description="Stop loss price")] = 1.16200,
    tp:         Annotated[float, Field(description="Take profit price")] = 1.16700,
    lots:       Annotated[float, Field(description="Position size in lots")] = 4.1,
    pnl:        Annotated[float, Field(description="Closed P&L in USD")] = 0.0,
    balance:    Annotated[float, Field(description="Account balance")] = 103537.0,
    deposit:    Annotated[float, Field(description="Initial deposit")] = 100000.0,
    dry_run:    Annotated[bool,  Field(description="Print message without sending")] = False,
) -> str:
    try:
        sys.path.insert(0, str(ROOT))
        from quantcore.alerts.notifier import Notifier, _tg_signal, _tg_trade_opened, _tg_trade_closed, _tg_phase_update, _tg_safety_warning, _tg_phase_passed
        n = Notifier()
        status = n.status()

        if dry_run:
            templates = {
                "signal":          _tg_signal(symbol,direction,score,price,sl,tp,lots),
                "trade_opened":    _tg_trade_opened(symbol,direction,lots,price,sl,tp),
                "trade_closed":    _tg_trade_closed(symbol,direction,lots,price,price+0.001,pnl),
                "phase_update":    _tg_phase_update(balance,deposit,8.0),
                "safety_warning":  _tg_safety_warning("Daily DD",3.2,5.0),
                "phase_passed":    _tg_phase_passed(balance,deposit),
            }
            msg = templates.get(alert_type, "Unknown alert type")
            return f"## 📋 Alert Preview ({alert_type})\n\n```\n{msg}\n```\n\n{status}"

        if alert_type == "signal":
            r = n.signal(symbol, direction, score, price, sl, tp, lots)
        elif alert_type == "trade_opened":
            r = n.trade_opened(symbol, direction, lots, price, sl, tp)
        elif alert_type == "trade_closed":
            r = n.trade_closed(symbol, direction, lots, price, price+(tp-price)*0.3, pnl)
        elif alert_type == "phase_update":
            r = n.phase_update(balance, deposit, 8.0, force=True)
        elif alert_type == "safety_warning":
            r = n.safety_warning("Daily DD", (deposit-balance)/deposit*100, 5.0)
        elif alert_type == "phase_passed":
            r = n.phase_passed(balance, deposit)
        else:
            return f"❌ Unknown alert_type: {alert_type}"

        sent_to = []
        if r and r.get("telegram"): sent_to.append("✅ Telegram")
        elif r and r.get("telegram") is False: sent_to.append("❌ Telegram (failed)")
        if r and r.get("discord"):  sent_to.append("✅ Discord")
        elif r and r.get("discord") is False: sent_to.append("❌ Discord (failed)")
        if not sent_to: sent_to = ["⚠️ No channels configured — set TELEGRAM_BOT_TOKEN or DISCORD_WEBHOOK_URL"]
        return f"## 📨 Alert Sent — {alert_type}\n\n" + "\n".join(sent_to)
    except Exception as e:
        return f"❌ Alert error: {e}"


@mcp.tool(name="quantcore_sync_history",
          description="Import an MT5 history CSV into the local SQLite database, return new trade count and updated Phase-1 stats. Optionally start the live file watcher.",
          annotations={"readOnlyHint":False})
def quantcore_sync_history(
    csv_path:    Annotated[Optional[str], Field(description="MT5 History CSV to import. Omit to show DB status.")] = None,
    watch_dir:   Annotated[Optional[str], Field(description="Start watcher on this directory (runs in background)")] = None,
    response_format: Annotated[str,       Field(description="'markdown' or 'json'")] = "markdown",
) -> str:
    try:
        sys.path.insert(0, str(ROOT))
        from quantcore.sync.mt5_watcher import MT5Watcher, _stats_from_db, _db_connect, parse_csv, _insert_trade
        import subprocess as sp

        if watch_dir:
            # Launch watcher as background process
            cmd = [sys.executable, str(ROOT/"quantcore"/"sync"/"mt5_watcher.py"),
                   "--watch", watch_dir, "--quiet"]
            sp.Popen(cmd, start_new_session=True)
            return f"✅ MT5 Watcher started on: `{watch_dir}`\nDropping any MT5 History CSV there will auto-sync."

        conn = _db_connect()
        new_count = 0
        if csv_path:
            if not Path(csv_path).exists():
                return f"❌ File not found: {csv_path}"
            trades = parse_csv(csv_path)
            for t in trades:
                if _insert_trade(conn, t): new_count += 1

        stats = _stats_from_db(conn)
        if response_format == "json":
            return json.dumps({**stats, "new_trades_imported": new_count}, indent=2)

        lines = [f"## 🔄 MT5 Sync\n"]
        if csv_path: lines.append(f"**{new_count} new trades imported** from `{Path(csv_path).name}`\n")
        lines += [
            f"|Field|Value|\n|---|---|",
            f"|Balance|**${stats['balance']:,.2f}**|",
            f"|Net P&L|${stats['total_pnl']:+,.2f} ({stats['net_pct']:+.2f}%)|",
            f"|Today|${stats['today_pnl']:+,.2f}|",
            f"|Phase-1|{stats['phase_pct']:.1f}% — ${stats['remaining']:,.2f} remaining|",
            f"|Trades|{stats['total_trades']} (WR {stats['win_rate']:.0f}%)|",
            f"|Drawdown|{stats['drawdown']:.2f}%|",
        ]
        return "\n".join(lines)
    except Exception as e:
        return f"❌ Sync error: {e}"


if __name__ == "__main__":
    mcp.run(transport="stdio")
