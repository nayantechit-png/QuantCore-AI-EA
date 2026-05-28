#!/usr/bin/env python3
"""
QuantCore AI EA — GoatFunded Performance Dashboard
Tracks prop firm challenge progress, QuantCore-specific trade stats,
and recommends parameter changes to maximise daily profit.

Usage:
    python dashboard/ea_dashboard.py              # demo (screenshot data)
    python dashboard/ea_dashboard.py --csv h.csv  # MT5 History tab → Save As CSV
    python dashboard/ea_dashboard.py --watch      # auto-refresh every 15 s
"""
import argparse, csv, sys, time, os
from datetime import datetime, date
from pathlib import Path
from collections import defaultdict

try:
    from rich.console import Console
    from rich.table import Table
    from rich.layout import Layout
    from rich.panel import Panel
    from rich.text import Text
    from rich.align import Align
    from rich.live import Live
    from rich.rule import Rule
    from rich.progress import BarColumn, Progress, TextColumn, MofNCompleteColumn
    from rich import box
except ImportError:
    print("pip install rich")
    sys.exit(1)

console = Console()

# ══════════════════════════════════════════════════════════════════════════════
#  DEMO DATA  (matches the GoatFunded screenshot)
# ══════════════════════════════════════════════════════════════════════════════

DEMO_ACCOUNT = dict(
    account_id  = "514733813",
    name        = "Faisal_Amir-Phase_1",
    broker      = "GoatFunded-Server3",
    balance     = 103_183.02,
    deposit     = 100_000.00,
    currency    = "USD",
    phase       = "Phase-1",
    target_pct  = 8.0,      # GoatFunded Phase-1 profit target %
    max_daily   = 5.0,      # GoatFunded daily loss limit %
    max_total   = 10.0,     # GoatFunded total drawdown limit %
)

# (date, symbol, side, lots, open_px, close_px, profit, comment)
DEMO_TRADES = [
    ("2026-05-26", "XAUUSD", "BUY",  0.02, 4520.07, 4524.49,   8.84, ""),
    ("2026-05-26", "XAUUSD", "BUY",  0.20, 4519.30, 4524.49, 103.80, ""),
    ("2026-05-26", "XAUUSD", "BUY",  0.20, 4525.05, 4519.58,-109.40, ""),
    ("2026-05-26", "XAUUSD", "BUY",  0.20, 4513.29, 4519.64, 127.00, ""),
    ("2026-05-26", "XAUUSD", "BUY",  0.20, 4510.01, 4519.64, 192.60, ""),
    ("2026-05-26", "GBPUSD", "BUY",  7.43, 1.34602, 1.34687, 631.55, "GFv8_M30_L"),
    ("2026-05-27", "AUDUSD", "BUY",  8.25, 0.71383, 0.71456, 602.25, "GFv8_M30_L"),
    ("2026-05-27", "AUDUSD", "BUY",  1.00, 0.71339, 0.71350,  11.00, ""),
    ("2026-05-27", "NZDUSD", "BUY",  1.00, 0.59029, 0.59024,  -5.00, ""),
    ("2026-05-27", "NZDUSD", "SELL", 8.27, 0.59006, 0.58933, 603.71, "GFv8_M30_S"),
    ("2026-05-27", "XAUUSD", "BUY",  0.29, 4434.51, 4451.84, 502.57, "GFv8_H1_L"),
    ("2026-05-28", "EURUSD", "BUY",  4.10, 1.16327, 1.16460, 545.30, "QuantCore[0.696]|0.127"),
]

# ══════════════════════════════════════════════════════════════════════════════
#  CSV LOADER  (MT5 History tab → right-click → Save As CSV)
# ══════════════════════════════════════════════════════════════════════════════

def load_csv(path: str) -> list[dict]:
    """Parse MT5 History CSV export. Handles common MT5 column layouts."""
    trades = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        sample = f.read(2048); f.seek(0)
        dialect = csv.Sniffer().sniff(sample, delimiters=",;\t")
        reader  = csv.DictReader(f, dialect=dialect)
        for row in reader:
            try:
                # Normalise column names (MT5 varies by locale)
                r = {k.strip().lower(): v.strip() for k, v in row.items()}
                profit = float(r.get("profit", 0) or 0)
                trades.append(dict(
                    date    = r.get("time", r.get("open time", ""))[:10],
                    symbol  = r.get("symbol", ""),
                    side    = r.get("type", r.get("direction", "")).upper(),
                    lots    = float(r.get("volume", r.get("lots", 0)) or 0),
                    open_px = float(r.get("price", r.get("open price", 0)) or 0),
                    close_px= float(r.get("close price", r.get("price (2)", 0)) or 0),
                    profit  = profit,
                    comment = r.get("comment", ""),
                ))
            except Exception:
                continue
    return trades

# ══════════════════════════════════════════════════════════════════════════════
#  ANALYTICS
# ══════════════════════════════════════════════════════════════════════════════

def analyse(trades: list, account: dict) -> dict:
    from datetime import timedelta
    deposit    = account["deposit"]
    balance    = account["balance"]
    target_pct = account["target_pct"]
    today      = date.today().isoformat()

    qc_trades = [t for t in trades if "QuantCore" in t.get("comment", "")]

    wins      = [t for t in trades if t["profit"] > 0]
    losses    = [t for t in trades if t["profit"] < 0]
    total_pnl = sum(t["profit"] for t in trades)
    today_pnl = sum(t["profit"] for t in trades if t["date"] == today)
    gross_win = sum(t["profit"] for t in wins)
    gross_los = abs(sum(t["profit"] for t in losses))

    qc_wins  = [t for t in qc_trades if t["profit"] > 0]
    qc_today = sum(t["profit"] for t in qc_trades if t["date"] == today)
    qc_avg_sc= _extract_scores(qc_trades)

    daily = defaultdict(float)
    for t in trades:
        daily[t["date"]] += t["profit"]

    # ── Pace tracking ─────────────────────────────────────────────────────────
    target_profit  = deposit * target_pct / 100        # e.g. $8,000
    remaining      = max(0, target_profit - total_pnl)
    days_active    = max(1, len(daily))
    avg_daily      = total_pnl / days_active            # actual avg P&L/day

    # Required daily pace to pass in fixed windows
    req_5d   = remaining / 5  if remaining > 0 else 0
    req_10d  = remaining / 10 if remaining > 0 else 0

    # Estimated pass date at current pace
    if avg_daily > 0 and remaining > 0:
        days_left_cur = remaining / avg_daily
        pass_date_cur = date.today() + timedelta(days=int(days_left_cur) + 1)
    elif remaining <= 0:
        days_left_cur = 0
        pass_date_cur = date.today()
    else:
        days_left_cur = 999
        pass_date_cur = None

    # With 3-symbol deployment estimate (×3 opportunities, ×1.33 risk)
    est_3sym_daily = avg_daily * 3.5          # 3 symbols + more signals
    if est_3sym_daily > 0 and remaining > 0:
        days_left_3sym = remaining / est_3sym_daily
        pass_date_3sym = date.today() + timedelta(days=int(days_left_3sym) + 1)
    elif remaining <= 0:
        days_left_3sym = 0
        pass_date_3sym = date.today()
    else:
        days_left_3sym = 999
        pass_date_3sym = None

    # ── Drawdown / prop firm ───────────────────────────────────────────────────
    dd_pct     = max(0, (deposit - balance) / deposit * 100)
    daily_dd   = dd_pct
    daily_used = min(100, daily_dd / account["max_daily"] * 100)
    total_used = min(100, dd_pct   / account["max_total"] * 100)

    profit_pct = (balance - deposit) / deposit * 100
    phase_pct  = min(100, profit_pct / target_pct * 100)

    return dict(
        trades         = trades,
        qc_trades      = qc_trades,
        total          = len(trades),
        wins           = len(wins),
        losses         = len(losses),
        win_rate       = len(wins) / len(trades) * 100 if trades else 0,
        total_pnl      = total_pnl,
        today_pnl      = today_pnl,
        qc_today       = qc_today,
        qc_total       = len(qc_trades),
        qc_wins        = len(qc_wins),
        qc_avg_sc      = qc_avg_sc,
        avg_win        = gross_win / len(wins)   if wins   else 0,
        avg_loss       = gross_los / len(losses) if losses else 0,
        profit_factor  = gross_win / gross_los   if gross_los else float("inf"),
        gross_win      = gross_win,
        gross_loss     = gross_los,
        daily          = dict(daily),
        days_active    = days_active,
        avg_daily      = avg_daily,
        target_profit  = target_profit,
        remaining      = remaining,
        req_5d         = req_5d,
        req_10d        = req_10d,
        days_left_cur  = days_left_cur,
        pass_date_cur  = pass_date_cur,
        days_left_3sym = days_left_3sym,
        pass_date_3sym = pass_date_3sym,
        dd_pct         = dd_pct,
        daily_dd_pct   = daily_dd,
        daily_used     = daily_used,
        total_used     = total_used,
        profit_pct     = profit_pct,
        phase_pct      = phase_pct,
        balance        = balance,
        deposit        = deposit,
    )

def _extract_scores(qc_trades: list) -> float:
    """Parse QuantCore[0.696]|0.127 comments → average signal score."""
    scores = []
    for t in qc_trades:
        c = t.get("comment", "")
        if "QuantCore[" in c:
            try:
                sc = float(c.split("[")[1].split("]")[0])
                scores.append(sc)
            except Exception:
                pass
    return sum(scores) / len(scores) if scores else 0.0

# ══════════════════════════════════════════════════════════════════════════════
#  PARAMETER OPTIMIZER
# ══════════════════════════════════════════════════════════════════════════════

DEPLOYED = dict(
    risk_pct      = 1.00,
    min_score     = 0.58,
    sl_atr_mult   = 1.5,
    tp_atr_mult   = 3.5,
    trail_atr     = 0.8,
    max_positions = 3,
    start_hour    = 1,
    end_hour      = 21,
)

def panel_deployed(stats: dict) -> Panel:
    """Shows the current deployed .set file params + symbol checklist."""
    from rich.columns import Columns

    # Left: deployed params
    pt = Table(box=box.SIMPLE, show_header=False, padding=(0, 2), expand=False)
    pt.add_column("Param",  style="dim", width=22)
    pt.add_column("Value",  style="bold green", width=10)
    rows = [
        ("Inp_RiskPerTrade",  f"{DEPLOYED['risk_pct']:.2f}%"),
        ("Inp_MinScore",      f"{DEPLOYED['min_score']:.2f}"),
        ("Inp_TP_ATR_Mult",   f"{DEPLOYED['tp_atr_mult']:.1f}×"),
        ("Inp_Trail_ATR",     f"{DEPLOYED['trail_atr']:.1f}×"),
        ("Inp_SL_ATR_Mult",   f"{DEPLOYED['sl_atr_mult']:.1f}×"),
        ("Inp_MaxPositions",  f"{DEPLOYED['max_positions']}"),
        ("Trading hours",     f"{DEPLOYED['start_hour']:02d}:00 – {DEPLOYED['end_hour']:02d}:00"),
        ("Max daily loss",    "4.5%  (GoatFunded 5%)"),
        ("Max total loss",    "9.0%  (GoatFunded 10%)"),
    ]
    for r, v in rows:
        pt.add_row(r, v)

    # Right: symbol checklist
    ct = Table(box=box.SIMPLE, show_header=False, padding=(0, 2), expand=False)
    ct.add_column("Status", width=4)
    ct.add_column("Action", style="white", width=32)
    checklist = [
        ("[bold green]✅[/]", "EURUSD.x H1 — running"),
        ("[bold yellow]⬜[/]", "GBPUSD.x H1 — drag EA + load .set"),
        ("[bold yellow]⬜[/]", "XAUUSD.x H1 — drag EA + load .set"),
        ("[dim]──[/]", ""),
        ("[dim]  [/]", "Navigator → Expert Advisors"),
        ("[dim]  [/]", "Drag QuantCore_AI_EA onto chart"),
        ("[dim]  [/]", "Properties → Load → .set file"),
        ("[dim]  [/]", "Confirm green Algo Trading ✓"),
    ]
    for s, a in checklist:
        ct.add_row(s, a)

    from rich.columns import Columns
    inner = Columns([pt, ct], expand=True)
    return Panel(inner, title="[bold green]⚙  DEPLOYED SETTINGS  +  MT5 CHECKLIST[/]",
                 border_style="green", padding=(0, 1))

# ══════════════════════════════════════════════════════════════════════════════
#  RICH PANELS
# ══════════════════════════════════════════════════════════════════════════════

def _bar(pct: float, width: int = 20, color: str = "green") -> str:
    filled = int(min(pct, 100) / 100 * width)
    bar    = "█" * filled + "░" * (width - filled)
    c = "red" if pct > 80 else "yellow" if pct > 50 else color
    return f"[{c}]{bar}[/]  {pct:.1f}%"

def panel_account(acc: dict, stats: dict) -> Panel:
    gain      = stats["balance"] - stats["deposit"]
    gain_pct  = stats["profit_pct"]
    today_abs = stats["today_pnl"]
    today_pct = today_abs / stats["deposit"] * 100

    lines = Text()
    lines.append(f"  Account   ", style="dim")
    lines.append(f"{acc['account_id']} — {acc['name']}\n", style="bold white")
    lines.append(f"  Broker    ", style="dim")
    lines.append(f"{acc['broker']}\n", style="white")
    lines.append(f"  Deposit   ", style="dim")
    lines.append(f"${stats['deposit']:>12,.2f}\n", style="white")
    c = "green" if gain >= 0 else "red"
    lines.append(f"  Balance   ", style="dim")
    lines.append(f"${stats['balance']:>12,.2f}\n", style=f"bold {c}")
    lines.append(f"  Net P&L   ", style="dim")
    lines.append(f"${gain:>+12,.2f}  ({gain_pct:+.2f}%)\n", style=f"bold {c}")
    tc = "green" if today_abs >= 0 else "red"
    lines.append(f"  Today     ", style="dim")
    lines.append(f"${today_abs:>+12,.2f}  ({today_pct:+.2f}%)\n", style=f"bold {tc}")

    lines.append(f"\n  Phase Target  {acc['target_pct']:.0f}%  ", style="dim")
    lines.append(f"{_bar(stats['phase_pct'], 16, 'green')}\n")

    if stats["remaining"] > 0:
        lines.append(f"  Remaining     ", style="dim")
        lines.append(f"${stats['remaining']:,.2f}  to pass\n", style="bold yellow")
        lines.append(f"  Avg/day       ", style="dim")
        lines.append(f"${stats['avg_daily']:,.2f}  ({stats['days_active']} days)\n", style="white")
        if stats["pass_date_cur"]:
            lines.append(f"  Pass date     ", style="dim")
            lines.append(f"{stats['pass_date_cur'].strftime('%d %b')}  "
                         f"(~{int(stats['days_left_cur'])+1} days, 1 symbol)\n", style="yellow")
        if stats["pass_date_3sym"]:
            lines.append(f"  With 3 syms   ", style="dim")
            lines.append(f"{stats['pass_date_3sym'].strftime('%d %b')}  "
                         f"(~{int(stats['days_left_3sym'])+1} days) 🚀\n", style="bold green")
    else:
        lines.append(f"  🎉 TARGET REACHED — SUBMIT FOR REVIEW!\n", style="bold green blink")

    return Panel(lines, title="[bold cyan]💰 ACCOUNT[/]", border_style="cyan", padding=(0,1))

def panel_propfirm(acc: dict, stats: dict) -> Panel:
    lines = Text()

    dl = acc["max_daily"];  du = stats["daily_used"]
    tl = acc["max_total"];  tu = stats["total_used"]
    dd = stats["dd_pct"]

    lines.append(f"  Daily Loss Limit   {dl:.1f}%\n", style="dim")
    lines.append(f"  {_bar(du, 22, 'green')}\n")
    lines.append(f"  Used: {stats['daily_dd_pct']:.2f}%  |  Buffer: {max(0, dl - stats['daily_dd_pct']):.2f}%\n\n", style="white")

    lines.append(f"  Total DD Limit     {tl:.1f}%\n", style="dim")
    lines.append(f"  {_bar(tu, 22, 'green')}\n")
    lines.append(f"  Used: {dd:.2f}%     |  Buffer: {max(0, tl - dd):.2f}%\n\n", style="white")

    safe_c = "bold green" if du < 50 and tu < 50 else "bold yellow" if du < 80 and tu < 80 else "bold red"
    status = "✅ SAFE — Plenty of buffer" if du < 50 and tu < 50 else "⚠️  Getting close" if du < 80 and tu < 80 else "🚨 DANGER ZONE"
    lines.append(f"  Status: {status}\n", style=safe_c)

    return Panel(lines, title="[bold magenta]🛡  PROP FIRM SAFETY[/]", border_style="magenta", padding=(0,1))

def panel_tradestats(stats: dict) -> Panel:
    lines = Text()
    lines.append(f"  All EAs\n", style="bold dim")
    lines.append(f"  Trades   ", style="dim");  lines.append(f"{stats['total']}\n", style="bold white")
    lines.append(f"  Win Rate ", style="dim");
    wc = "bold green" if stats['win_rate'] > 55 else "bold yellow"
    lines.append(f"{stats['win_rate']:.1f}%\n", style=wc)
    lines.append(f"  Avg Win  ", style="dim");  lines.append(f"${stats['avg_win']:,.2f}\n", style="green")
    lines.append(f"  Avg Loss ", style="dim");  lines.append(f"-${stats['avg_loss']:,.2f}\n", style="red")
    pf = stats["profit_factor"]
    pfc = "bold green" if pf > 1.5 else "yellow"
    lines.append(f"  P. Factor", style="dim");  lines.append(f"{pf:.2f}\n", style=pfc)
    lines.append(f"  Gross Win", style="dim");  lines.append(f"${stats['gross_win']:,.2f}\n", style="green")
    lines.append(f"  Gross Los", style="dim");  lines.append(f"-${stats['gross_loss']:,.2f}\n", style="red")

    lines.append(f"\n  QuantCore AI Only\n", style="bold cyan")
    lines.append(f"  Signals  ", style="dim");  lines.append(f"{stats['qc_total']}\n", style="bold white")
    qcwr = stats['qc_wins'] / max(1, stats['qc_total']) * 100
    lines.append(f"  Win Rate ", style="dim");  lines.append(f"{qcwr:.0f}%\n", style="bold green")
    if stats["qc_avg_sc"] > 0:
        lines.append(f"  Avg Score", style="dim")
        lines.append(f"{stats['qc_avg_sc']:.3f}\n", style="bold yellow")
    lines.append(f"  Today    ", style="dim");
    lines.append(f"${stats['qc_today']:+,.2f}\n", style="bold green" if stats['qc_today'] >= 0 else "bold red")

    return Panel(lines, title="[bold green]📊 TRADE STATS[/]", border_style="green", padding=(0,1))

def panel_recent(stats: dict) -> Panel:
    t = Table(box=box.SIMPLE, show_header=True, header_style="bold cyan",
              expand=True, padding=(0,1))
    t.add_column("Date",    width=11, style="dim")
    t.add_column("Symbol",  width=7)
    t.add_column("Side",    width=5)
    t.add_column("Lots",    width=5, justify="right")
    t.add_column("Open",    width=9, justify="right")
    t.add_column("Close",   width=9, justify="right")
    t.add_column("P&L",     width=9, justify="right")
    t.add_column("EA",      width=14)

    for tr in sorted(stats["trades"], key=lambda x: x["date"], reverse=True)[:10]:
        pnl  = tr["profit"]
        pc   = "bold green" if pnl > 0 else "bold red"
        side_c = "cyan" if tr["side"] == "BUY" else "magenta"
        ea_label = "QuantCore ✨" if "QuantCore" in tr.get("comment","") else tr.get("comment","")[:12] or "—"
        ea_c = "bold yellow" if "QuantCore" in tr.get("comment","") else "dim"
        t.add_row(
            tr["date"],
            tr["symbol"],
            f"[{side_c}]{tr['side']}[/]",
            f"{tr['lots']:.2f}",
            f"{tr['open_px']:.4f}" if tr['open_px'] < 100 else f"{tr['open_px']:,.2f}",
            f"{tr['close_px']:.4f}" if tr['close_px'] < 100 else f"{tr['close_px']:,.2f}",
            f"[{pc}]${pnl:+,.2f}[/]",
            f"[{ea_c}]{ea_label}[/]",
        )

    return Panel(t, title="[bold white]📋 RECENT TRADES (last 10)[/]", border_style="white", padding=(0,0))

def panel_daily_pnl(stats: dict) -> Panel:
    t = Table(box=box.SIMPLE, header_style="bold cyan", padding=(0, 2))
    t.add_column("Date",     width=12, style="dim")
    t.add_column("P&L",      width=10, justify="right")
    t.add_column("Bar",      width=30)

    days = sorted(stats["daily"].items())
    max_abs = max(abs(v) for v in stats["daily"].values()) if stats["daily"] else 1

    for d, pnl in days[-7:]:   # last 7 trading days
        pc = "bold green" if pnl >= 0 else "bold red"
        bar_w = int(abs(pnl) / max_abs * 24)
        bar_c = "green" if pnl >= 0 else "red"
        bar   = f"[{bar_c}]{'█' * bar_w}[/]"
        t.add_row(d, f"[{pc}]${pnl:+,.2f}[/]", bar)

    return Panel(t, title="[bold blue]📅 DAILY P&L[/]", border_style="blue", padding=(0,0))

def panel_countdown(stats: dict, acc: dict) -> Panel:
    """Mission countdown — how many days / how much per day to pass."""
    lines = Text()

    remaining  = stats["remaining"]
    avg_daily  = stats["avg_daily"]
    deposit    = stats["deposit"]

    # Required pace to hit target in 5 / 10 / 20 trading days
    lines.append("  To pass in…\n", style="bold dim")
    for days, label in [(5, "5 days "), (10, "10 days"), (20, "20 days")]:
        req = remaining / days if remaining > 0 else 0
        pct = req / deposit * 100
        c   = "bold green" if req <= avg_daily * 1.5 else "yellow" if req <= avg_daily * 3 else "dim red"
        lines.append(f"    {label}  ", style="dim")
        lines.append(f"${req:>8,.0f}/day  ({pct:.2f}%)\n", style=c)

    lines.append(f"\n  Your actual avg  ", style="dim")
    ac = "bold green" if avg_daily > 0 else "red"
    lines.append(f"${avg_daily:>8,.0f}/day\n", style=ac)

    # Current-pace pass date
    lines.append(f"\n  At current pace   ", style="dim")
    if stats["pass_date_cur"]:
        lines.append(f"{stats['pass_date_cur'].strftime('%d %b %Y')}", style="yellow")
        lines.append(f"  (~{int(stats['days_left_cur'])+1} days)\n")
    else:
        lines.append("N/A\n", style="dim")

    # 3-symbol pass date
    lines.append(f"  With 3 symbols    ", style="dim")
    if stats["pass_date_3sym"]:
        lines.append(f"{stats['pass_date_3sym'].strftime('%d %b %Y')}", style="bold green")
        lines.append(f"  (~{int(stats['days_left_3sym'])+1} days) 🚀\n")

    # Daily target bar — how close today is to what's needed for 10-day pace
    needed_pct = min(100, stats["today_pnl"] / max(stats["req_10d"], 1) * 100) if stats["req_10d"] > 0 else 100
    lines.append(f"\n  Today vs 10-day target  ${stats['req_10d']:,.0f}\n", style="dim")
    lines.append(f"  {_bar(needed_pct, 22, 'green')}\n")

    return Panel(lines, title="[bold yellow]🎯 PHASE-1 COUNTDOWN[/]", border_style="yellow", padding=(0,1))

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN RENDER
# ══════════════════════════════════════════════════════════════════════════════

def render(account: dict, trades: list) -> None:
    stats = analyse(trades, account)
    now   = datetime.now().strftime("%Y-%m-%d  %H:%M:%S")
    console.print()
    console.rule(f"[bold cyan]  QuantCore AI EA — GoatFunded Performance Dashboard  |  {now}  [/]")
    console.print()

    # Row 1: Account | PropFirm | Stats
    from rich.columns import Columns
    console.print(Columns([
        panel_account(account, stats),
        panel_propfirm(account, stats),
        panel_tradestats(stats),
    ], equal=True, expand=True))

    console.print()

    # Row 2: Daily P&L | Phase-1 Countdown
    console.print(Columns([
        panel_daily_pnl(stats),
        panel_countdown(stats, account),
    ], equal=True, expand=True))

    console.print()

    # Row 3: Deployed settings + MT5 checklist (full width)
    console.print(panel_deployed(stats))

    console.print()

    # Row 4: Recent trades (full width)
    console.print(panel_recent(stats))

    console.print()
    console.rule("[dim]MT5 → History tab → right-click → Save As CSV  →  python dashboard/ea_dashboard.py --csv file.csv[/dim]")

# ══════════════════════════════════════════════════════════════════════════════
#  CLI
# ══════════════════════════════════════════════════════════════════════════════

def main():
    ap = argparse.ArgumentParser(description="QuantCore EA Performance Dashboard")
    ap.add_argument("--csv",   help="MT5 History export CSV file", default=None)
    ap.add_argument("--watch", help="Auto-refresh every N seconds", type=int, default=0)
    args = ap.parse_args()

    account = DEMO_ACCOUNT.copy()

    if args.csv:
        trades = load_csv(args.csv)
        if not trades:
            console.print("[red]No trades found in CSV. Check file format.[/]")
            sys.exit(1)
        # Infer balance from cumulative profit
        total_pnl = sum(t["profit"] for t in trades)
        account["balance"] = account["deposit"] + total_pnl
        console.print(f"[green]Loaded {len(trades)} trades from {args.csv}[/]")
    else:
        trades = [dict(
            date    = t[0],
            symbol  = t[1],
            side    = t[2],
            lots    = t[3],
            open_px = t[4],
            close_px= t[5],
            profit  = t[6],
            comment = t[7],
        ) for t in DEMO_TRADES]
        console.print("[dim yellow]Demo mode — using screenshot data. Use --csv for live data.[/]")

    if args.watch and args.watch > 0:
        try:
            while True:
                console.clear()
                render(account, trades)
                if args.csv:
                    trades = load_csv(args.csv)
                    total_pnl = sum(t["profit"] for t in trades)
                    account["balance"] = account["deposit"] + total_pnl
                time.sleep(args.watch)
        except KeyboardInterrupt:
            console.print("\n[dim]Dashboard stopped.[/]")
    else:
        render(account, trades)

if __name__ == "__main__":
    main()
