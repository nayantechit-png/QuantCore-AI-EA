"""
QuantCore MT5 History Auto-Sync
=================================
Watches a folder for new MT5 history CSV exports, parses them
automatically, updates the dashboard, fires Telegram/Discord alerts
for new trades, and logs everything to a SQLite database.

How it works
------------
1. MT5 History tab → right-click → "Save As" → choose the watch folder
2. This script detects the new/modified CSV in real time (via polling)
3. Parses new trades (compares to DB), fires alerts, refreshes dashboard
4. Runs continuously — restart on machine boot via launchd/cron

Watch folder
  Default: ~/Desktop/QuantCore-MT5-History/

File pattern
  Any *.csv in the watch folder (MT5 exports)

Database
  quantcore/sync/history.db  (SQLite)

Usage
-----
  # Start the watcher
  python mt5_watcher.py --watch ~/Desktop/QuantCore-MT5-History

  # One-shot: just import a file
  python mt5_watcher.py --import history.csv

  # Status report
  python mt5_watcher.py --status

  # With alerts enabled
  TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy \\
  python mt5_watcher.py --watch ~/Desktop/QuantCore-MT5-History
"""

import argparse, csv, hashlib, json, os, sqlite3, sys, time
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Optional
from collections import defaultdict

ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(ROOT))

DEPOSIT    = float(os.environ.get("QC_DEPOSIT",    "100000"))
TARGET_PCT = float(os.environ.get("QC_TARGET_PCT", "8.0"))
MAX_DAILY  = float(os.environ.get("QC_MAX_DAILY",  "5.0"))
MAX_TOTAL  = float(os.environ.get("QC_MAX_TOTAL",  "10.0"))

# ══════════════════════════════════════════════════════════════════════
#  DATABASE
# ══════════════════════════════════════════════════════════════════════

DB_PATH = Path(__file__).parent / "history.db"


def _db_connect() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("""
        CREATE TABLE IF NOT EXISTS trades (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            trade_hash   TEXT    UNIQUE,
            date         TEXT,
            symbol       TEXT,
            side         TEXT,
            lots         REAL,
            open_px      REAL,
            close_px     REAL,
            profit       REAL,
            comment      TEXT,
            imported_at  TEXT
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS sync_log (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            ts         TEXT,
            file_path  TEXT,
            trades_new INTEGER,
            message    TEXT
        )
    """)
    conn.commit()
    return conn


def _trade_hash(t: dict) -> str:
    key = f"{t['date']}|{t['symbol']}|{t['side']}|{t['lots']}|{t['open_px']}|{t['close_px']}"
    return hashlib.md5(key.encode()).hexdigest()


def _insert_trade(conn: sqlite3.Connection, t: dict) -> bool:
    """Insert trade; return True if new."""
    h = _trade_hash(t)
    try:
        conn.execute("""
            INSERT INTO trades (trade_hash,date,symbol,side,lots,open_px,close_px,
                                profit,comment,imported_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)
        """, (h, t["date"], t["symbol"], t["side"], t["lots"],
              t["open_px"], t["close_px"], t["profit"], t["comment"],
              datetime.utcnow().isoformat()))
        conn.commit()
        return True
    except sqlite3.IntegrityError:
        return False   # already exists


def _all_trades(conn: sqlite3.Connection) -> list[dict]:
    return [dict(r) for r in conn.execute(
        "SELECT * FROM trades ORDER BY date DESC, id DESC")]


def _stats_from_db(conn: sqlite3.Connection) -> dict:
    trades = _all_trades(conn)
    wins   = [t for t in trades if t["profit"] > 0]
    losses = [t for t in trades if t["profit"] < 0]
    pnl    = sum(t["profit"] for t in trades)
    bal    = DEPOSIT + pnl
    daily: dict = defaultdict(float)
    for t in trades: daily[t["date"]] += t["profit"]
    today_pnl = daily.get(date.today().isoformat(), 0.0)
    days_act  = max(1, len(daily))
    avg_day   = pnl / days_act
    phase_pct = min(100, pnl / (DEPOSIT * TARGET_PCT / 100) * 100) if DEPOSIT > 0 else 0
    remaining = max(0, DEPOSIT * TARGET_PCT / 100 - pnl)
    return dict(balance=round(bal,2), deposit=DEPOSIT,
                total_pnl=round(pnl,2), net_pct=round(pnl/DEPOSIT*100,2),
                today_pnl=round(today_pnl,2), phase_pct=round(phase_pct,1),
                remaining=round(remaining,2),
                avg_daily=round(avg_day,2),
                total_trades=len(trades), wins=len(wins), losses=len(losses),
                win_rate=round(len(wins)/max(len(trades),1)*100,1),
                drawdown=round(max(0,(DEPOSIT-bal)/DEPOSIT*100),2),
                daily=dict(daily))


# ══════════════════════════════════════════════════════════════════════
#  CSV PARSER  (reuse from dashboard)
# ══════════════════════════════════════════════════════════════════════

def parse_csv(path: str) -> list[dict]:
    trades = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        sample = f.read(2048); f.seek(0)
        try:    dialect = csv.Sniffer().sniff(sample, delimiters=",;\t")
        except: dialect = csv.excel
        for row in csv.DictReader(f, dialect=dialect):
            try:
                r = {k.strip().lower(): v.strip() for k,v in row.items()}
                trades.append({
                    "date":     r.get("time", r.get("open time",""))[:10],
                    "symbol":   r.get("symbol",""),
                    "side":     r.get("type", r.get("direction","")).upper(),
                    "lots":     float(r.get("volume", r.get("lots",0)) or 0),
                    "open_px":  float(r.get("price",  r.get("open price",0)) or 0),
                    "close_px": float(r.get("close price", r.get("price (2)",0)) or 0),
                    "profit":   float(r.get("profit",0) or 0),
                    "comment":  r.get("comment",""),
                })
            except: pass
    return trades


# ══════════════════════════════════════════════════════════════════════
#  ALERT INTEGRATION
# ══════════════════════════════════════════════════════════════════════

def _fire_alerts(new_trades: list[dict], stats: dict) -> None:
    """Send Telegram/Discord alerts for each new trade."""
    try:
        from quantcore.alerts.notifier import Notifier
        n = Notifier()
    except Exception:
        return

    for t in new_trades:
        try:
            n.trade_closed(
                symbol    = t["symbol"],
                direction = t["side"],
                lots      = t["lots"],
                open_price= t["open_px"],
                close_price=t["close_px"],
                pnl       = t["profit"],
            )
        except Exception:
            pass

    # Phase milestone alert
    try:
        n.phase_update(stats["balance"], stats["deposit"], TARGET_PCT)
    except Exception:
        pass

    # Safety warning
    if stats["drawdown"] >= MAX_DAILY * 0.6:
        try:
            n.safety_warning("Daily DD", stats["drawdown"], MAX_DAILY)
        except Exception:
            pass

    # Phase passed!
    if stats["phase_pct"] >= 100:
        try:
            n.phase_passed(stats["balance"], stats["deposit"])
        except Exception:
            pass


# ══════════════════════════════════════════════════════════════════════
#  DASHBOARD REFRESH
# ══════════════════════════════════════════════════════════════════════

def _print_dashboard(stats: dict, new_count: int = 0) -> None:
    """Compact live terminal status."""
    now = datetime.utcnow().strftime("%H:%M:%S UTC")
    print(f"\r{'─'*60}")
    print(f"  ⚡ QuantCore Live Sync  |  {now}")
    print(f"{'─'*60}")
    print(f"  Balance   ${stats['balance']:>12,.2f}   Net P&L  ${stats['total_pnl']:>+10,.2f} ({stats['net_pct']:+.2f}%)")
    print(f"  Today     ${stats['today_pnl']:>+12,.2f}   Avg/day  ${stats['avg_daily']:>+10,.2f}")
    bar_fill = int(stats['phase_pct'] / 5); bar_empty = 20 - bar_fill
    bar = "█"*bar_fill + "░"*bar_empty
    print(f"  Phase-1   [{bar}] {stats['phase_pct']:.1f}%  Remaining ${stats['remaining']:,.2f}")
    dd_c = "🔴" if stats['drawdown'] > MAX_DAILY*0.8 else "🟡" if stats['drawdown'] > MAX_DAILY*0.5 else "🟢"
    print(f"  Drawdown  {dd_c} {stats['drawdown']:.2f}% / {MAX_DAILY:.0f}%   Trades {stats['total_trades']}  WR {stats['win_rate']:.0f}%")
    if new_count:
        print(f"  ✅ {new_count} new trade(s) imported")
    print(f"{'─'*60}", flush=True)


# ══════════════════════════════════════════════════════════════════════
#  FILE WATCHER
# ══════════════════════════════════════════════════════════════════════

class MT5Watcher:
    """
    Poll a directory for new/modified MT5 CSV files.
    On change: parse → insert new trades → alert → update dashboard.
    """

    def __init__(self, watch_dir: str, poll_interval: int = 15,
                 verbose: bool = True):
        self.watch_dir     = Path(watch_dir).expanduser()
        self.poll_interval = poll_interval
        self.verbose       = verbose
        self._file_mtimes: dict = {}
        self._conn = _db_connect()
        self.watch_dir.mkdir(parents=True, exist_ok=True)

    def scan_once(self) -> int:
        """Scan for new/modified CSVs. Returns number of new trades imported."""
        total_new = 0
        for csv_path in self.watch_dir.glob("*.csv"):
            mtime = csv_path.stat().st_mtime
            if self._file_mtimes.get(str(csv_path)) == mtime:
                continue   # unchanged
            self._file_mtimes[str(csv_path)] = mtime

            trades = parse_csv(str(csv_path))
            new_trades = []
            for t in trades:
                if _insert_trade(self._conn, t):
                    new_trades.append(t)

            if new_trades:
                total_new += len(new_trades)
                stats = _stats_from_db(self._conn)
                if self.verbose:
                    print(f"\n  📥 {csv_path.name}: {len(new_trades)} new trades")
                _fire_alerts(new_trades, stats)
                self._conn.execute(
                    "INSERT INTO sync_log (ts,file_path,trades_new,message) VALUES (?,?,?,?)",
                    (datetime.utcnow().isoformat(), str(csv_path),
                     len(new_trades), f"Imported {len(new_trades)} trades"))
                self._conn.commit()

        return total_new

    def run(self) -> None:
        print(f"\n  🔍 Watching: {self.watch_dir}")
        print(f"  📡 Poll interval: {self.poll_interval}s")
        print(f"  💾 Database: {DB_PATH}")
        print(f"\n  Drop any MT5 History CSV into the watch folder.\n")
        try:
            while True:
                new = self.scan_once()
                stats = _stats_from_db(self._conn)
                if self.verbose:
                    _print_dashboard(stats, new)
                time.sleep(self.poll_interval)
        except KeyboardInterrupt:
            print("\n  Watcher stopped.")

    def status(self) -> str:
        stats = _stats_from_db(self._conn)
        lines = [
            f"QuantCore MT5 Sync Status",
            f"  Watch dir : {self.watch_dir}",
            f"  Database  : {DB_PATH}",
            f"  Trades    : {stats['total_trades']}",
            f"  Balance   : ${stats['balance']:,.2f}",
            f"  Net P&L   : ${stats['total_pnl']:+,.2f} ({stats['net_pct']:+.2f}%)",
            f"  Phase     : {stats['phase_pct']:.1f}% of {TARGET_PCT:.0f}%",
            f"  Win Rate  : {stats['win_rate']:.1f}%",
        ]
        return "\n".join(lines)

    def import_file(self, path: str) -> int:
        trades = parse_csv(path)
        n = sum(1 for t in trades if _insert_trade(self._conn, t))
        print(f"  ✅ Imported {n} new trades from {path}")
        return n


# ══════════════════════════════════════════════════════════════════════
#  CLI
# ══════════════════════════════════════════════════════════════════════

def main():
    ap = argparse.ArgumentParser(description="QuantCore MT5 History Watcher")
    ap.add_argument("--watch",    default=None,   help="Watch directory path")
    ap.add_argument("--import",   dest="imp",     help="One-shot import a CSV file")
    ap.add_argument("--status",   action="store_true", help="Show sync status")
    ap.add_argument("--interval", type=int, default=15, help="Poll interval seconds")
    ap.add_argument("--quiet",    action="store_true")
    args = ap.parse_args()

    default_dir = Path.home() / "Desktop" / "QuantCore-MT5-History"
    watch_dir   = args.watch or str(default_dir)
    watcher = MT5Watcher(watch_dir, args.interval, not args.quiet)

    if args.imp:
        watcher.import_file(args.imp)
    elif args.status:
        print(watcher.status())
    else:
        watcher.run()


if __name__ == "__main__":
    main()
